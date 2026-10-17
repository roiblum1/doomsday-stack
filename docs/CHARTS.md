# CHARTS.md — Helm chart catalogue of the LLM serving platform

Companion to `GITOPS.md` (same archive, same audience). Sanitization conventions and the
cluster/site vocabulary are defined in `GITOPS.md` §0. Registry prefixes are normalized to
`registry-internal/` (tags/digests verbatim); all other identifiers are as in the sources.

## 1. Chart inventory

| Chart | Version | Source dir (`charts/…`) | Deploys | Target namespace(s) |
|---|---|---|---|---|
| `glm53-bundled` | 0.1.0 (appVersion `glm-5.3`) | `glm53-bundled/` | GLM-5.3 serving bundle: storage prep, model pull, vLLM LLMInferenceService, gateway route | `llm-glm53` |
| `qwen38-bundled` | 0.2.7 | `qwen38-bundled/` | Qwen3.8-27B-FP8 bundle incl. LMCacheEngine CR | `llm-qwen38` |
| `qwen36-judge` | 0.2.2 | `qwen36-judge/` | judge model + OpenAI-quota route | `llm-judge` |
| `generic-model` | 0.1.0 | `generic-model/` | unified model chart that supersedes the three above | any (values) |
| `llm-model` | 0.1.0 | `llm-model/` | gateway-side objects for a model served by another chart | model's namespace |
| `envoy-ai-gateway-openshift` | 0.1.0 (appVersion `v1.2.0`) | `envoy-ai-gateway/` | Envoy AI Gateway: Gateway, GatewayClass, ratelimit, routes | `envoy-ai-gateway-system` |
| `ai-gateway-helm` *(upstream dep)* | v1.2.0 | `upstream-subcharts/ai-gateway-helm-v1.2.0/` | AI Gateway controller + admission webhook | `envoy-ai-gateway-system` |
| `envoy-gateway-openshift` | 0.1.0 (appVersion `v1.9.1`) | `envoy-gateway/` | Envoy Gateway control plane + gateway.envoyproxy.io CRDs | `envoy-gateway-system` |
| `gateway-helm` *(upstream dep)* | v1.9.1 (+ `crds` subchart) | `upstream-subcharts/gateway-helm-v1.9.1/` | EG controller, certgen, webhooks | `envoy-gateway-system` |
| `platform/catalog-sources` | 0.1.0 | `platform/catalog-sources/` | OLM CatalogSources | `openshift-marketplace` |
| `platform/gpu` | 26.3.3 | `platform/gpu/` | GPU operator (OLM) + ClusterPolicy + NVIDIADriver + clock-lock | `nvidia-gpu-operator` |
| `platform/network` | 26.4.1 | `platform/network/` | NVIDIA network + maintenance operators, NicClusterPolicy | `nvidia-network-operator`, `nvidia-maintenance-operator` |
| `platform/lvms` | 4.22.0 | `platform/lvms/` | LVM Storage operator + LVMCluster | `openshift-storage` |
| `platform/nfd` | 4.22.0 | `platform/nfd/` | Node Feature Discovery operator + instance | `openshift-nfd` |
| `platform/nmstate-rdma` | 4.22.0 | `platform/nmstate-rdma/` | kubernetes-nmstate + RDMA NodeNetworkConfigurationPolicies | `openshift-nmstate` |
| `platform/numaresources` | 4.22.1 | `platform/numaresources/` | NUMA Resources operator + NUMAResourcesOperator CR | `openshift-numaresources` |
| `platform/istio` | 3.4.1 | `platform/istio/` | Service Mesh 3 (Sail) operator + Istio/IstioCNI CRs | `openshift-operators`, `istio-system`, `istio-cni` |
| `platform/lws` | 1.0.0 | `platform/lws/` | LeaderWorkerSet operator | `openshift-lws-operator` |
| `platform/monitoring` | 4.2.0 | `platform/monitoring/` | 4 vendored subcharts: `rdma-exporter` 4.2.0, `hpc-observability` 0.1.6, `prometheus-mcp` 1.1.0, `grafana` 9.2.4 | `rdma-monitoring`, `openshift-monitoring`, `prometheus-mcp` |

Referenced by ArgoCD apps but **not exported**: `kserve-chart.git` and `lmcache-chart.git`
(their objects are visible only in `live-cluster/`).

## 2. Charts in detail

### 2.1 `glm53-bundled` 0.1.0 — flagship model bundle (GLM-5.3)

Registered by `operators/glm53` (chart repo pinned to branch `bundled`). Renders ~29 objects
(per the verification table in `generic-model/README.md`) into `llm-glm53`. Full
template-by-template walk in §4.

**Key values** (`glm53-bundled/values.yaml`, 401 lines):

| Concern | Value |
|---|---|
| model | `glm-5.3`, S3 path `llms/zai-org/GLM-5.3` (pulled to PVC, served as `pvc://…`), second served id `publishers/llm-glm53/models/glm-5.3` |
| replicas | 2 (one pod per B200 node; `nodes: [gpu-node-1, gpu-node-2]`) |
| parallelism | DP8 × EP8: `--data-parallel-size=8 --data-parallel-size-local=8 --data-parallel-multi-port-external-lb --data-parallel-supervisor-port=8208 --enable-expert-parallel --all2all-backend=allgather_reducescatter` |
| vLLM memory | `--kv-cache-dtype=fp8_e4m3 --gpu-memory-utilization=0.90 --max-model-len=262144 --max-num-seqs=64 --max-num-batched-tokens=16384 --enable-prefix-caching` |
| speculative decode | MTP: `--speculative-config.method=mtp --speculative-config.num_speculative_tokens=5`, parsers `glm47` |
| per-pod resources | 8 × `nvidia.com/gpu`, CPU 96→192, memory 512Gi→2000Gi, `hugepages-1Gi: 16Gi`, dshm 600Gi |
| placement | `runtimeClassName: performance-gpu-hpc-performanceprofile-extras-b200`, `maxSurge: 0` (no free GPUs for a surge pod) |
| KV offload | KServe `kvCacheOffloading.cpu: 64Gi` (CPU offload tier — **not** LMCacheEngine) |
| storage | node-prep LVs `llm-models` 1200G + `llm-cache` 300G from VG `vg1`; static PVs 1200Gi/300Gi with nodeAffinity spanning both nodes; PVCs pinned via `volumeName` |
| images | `vllm/vllm-openai:v0.30.0`, `s5cmd:v2.3.0` (registry-internal mirrors); storage-initializer comes from the kserve preset |
| EPP scheduler | service `glm53-b200-epp-service:9002`; plugins single-profile-handler, approx-prefix-cache-producer, inflight-load-producer, prefix-cache-scorer, active-request-scorer, token-load-scorer, max-score-picker; scheduling profile weights: active-request-scorer **3**, token-load-scorer 1, prefix-cache-scorer 1 |
| Flow control | `llmisvc.flowControl`, off: with `enabled=true` the template adds the feature gate, `concurrency-detector` (`maxConcurrency` required, **per rank endpoint**, ≤ `--max-num-seqs=64`), `requestTTL` 300s and `round-robin-fairness-policy` on the default (and negative) band to the profile above. Same block in `qwen38-bundled` |
| InferencePool | selector on kserve workload labels, `targetPorts` 8000–8007 (one endpoint per pod-rank) |

**Design choices** (each documented in the chart's README/values comments):

- **node-prep DaemonSet**: privileged pod, `nsenter -t 1` into the host mount namespace,
  creates/mounts XFS LVs and relabels with `container_file_t`; mounts survive container exit;
  a 60 s loop re-reconciles (LVMS uses thick LVs, so the model/cache LVs are carved manually).
- **Per-node pull Jobs**: `s5cmd` sync from S3 straight into the mounted LV, idempotent via a
  `.download-complete` marker, `backoffLimit: 3`.
- **Multi-port external DP LB**: 8 rank API servers on 8000–8007 + supervisor on 8208 (probes);
  the EPP sees one endpoint per (pod, rank), so it balances at rank level — vLLM's internal DP
  balancer otherwise double-loads ranks (measured, values comment 2026-10-04).
- **Anthropic direct path bypasses the EPP**: `glm53-anthropic` AIServiceBackend (schema
  Anthropic) + chart-owned ranks Service + Backend with one FQDN endpoint per rank port
  (16 endpoints). llm-d-router cannot parse Anthropic bodies, so EPP scheduling would be blind.
- **AIGatewayRoute rules** (first match wins): `glm-5.3` → Anthropic backend;
  `publishers/llm-glm53/models/glm-5.3` → InferencePool/EPP; `^claude-.*$` regex alias →
  Anthropic backend + `modelNameOverride: glm-5.3` (safety net for unremapped Claude Code
  clients). `llmRequestCosts` metadata keys: `llm_input_token`, `llm_output_token`,
  `llm_reasoning_token`, `llm_total_token`.
- **Custom SCC** `glm53-model-serving` (modeled on `anyuid` + `IPC_LOCK`, priority 9) granted
  via Role/RoleBinding instead of loosening cluster-wide SCCs.
- `s3Secret.create: false` — S3 credentials Secret is pre-created out-of-band.
- `aiperf` benchmark Job disabled by default (token-level tuning knobs in values).

### 2.2 `qwen38-bundled` 0.2.7 — Qwen3.8-27B-FP8 with LMCache

Renders into `llm-qwen38`: namespace, SA, SCC (`qwen38-model-serving`), s3-secret,
node-prep, local-storage, pull-jobs, `LLMInferenceService` `qwen38-l4`, `LMCacheEngine`
`qwen38-cache`, aigatewayroute, anthropic-backend, prometheusrule + monitoring RBAC
(12 templates + `_helpers.tpl`).

**Key values** (`qwen38-bundled/values.yaml`, 505 lines):

| Concern | Value |
|---|---|
| model | `qwen3-8-27b-fp8`, S3 path `llms/Qwen/Qwen3.8-27B-FP8` |
| replicas | 1 on the L4 node (`nodeSelector nvidia.com/gpu.product: NVIDIA-L4` → `util-node-1`) |
| parallelism | TP4 × DP1, **internal** DP LB (single port 8000) — values comment records the TP2×DP3 → TP4×DP1 change (chunk-size/block alignment) |
| images | model pod `lmcache/lmcache/vllm-openai:v0.5.5` (LMCache-enabled build); node-prep uses plain `vllm/vllm-openai:v0.30.0` |
| LMCacheEngine | CR `qwen38-cache` (= CR + Service + `-metrics` job), engine image tag-for-tag with the model pod (both sides of the ZMQ/CUDA-IPC protocol must match), server ZMQ 5555 / http 8080 |
| L1 tier | pinned RAM 200 GiB per node (pod request 205Gi / limit 307Gi), LRU eviction, watermark 0.8, ratio 0.2 |
| L2 tier | 900 GiB capacity cap on a dedicated 1000Gi local-static PVC (`qwen38-cache-l2`, subdir `lmcache-l2`, backed by node-prep LV `vg1/llm-l2`), `shardDirs: true`, `persist: true`, LRU 0.9/0.1 |
| flow control | `llmisvc.flowControl`, off; as in glm53 (one endpoint per pod here, `--max-num-seqs=32`) |
| chunkSize | 1600 — TP4+MTP block alignment demanded by the connector (v0.2.5 crash note); changing it invalidates existing L2 chunk keys |
| routing | `isolatedIPC: true` (driver-level CUDA IPC; no hostIPC), `priorityClassName: openshift-user-critical` |

**Design choices**:

- **LMCacheEngine CR rendered by the model chart**, while the operator/CRDs come from the
  separate `lmcache` Argo app — the engine must live with the model because its image must be
  build-locked with the vLLM pod (`lmcache.*` keys mirror the upstream lmcache-engine chart 1:1).
- **flashinfer cubin seeding**: the lmcache `v0.5.5` image ships flashinfer without trtllm-gen
  cubins (air-gap: no runtime download), so node-prep seeds them **from the
  `vllm-openai:v0.30.0` image** (which bundles the same cubins) into the cache LV — a sidecar
  copies the files through `/proc/<pid>/root` of the running node-prep container; the vLLM args
  gain a marker flag (`lmcache-cubin-src`) so the engine can attribute the source.
- **Cache observability**: `prometheusrule.yaml` + `monitoring-rbac.yaml` wire the engine's
  metrics (http frontend :8080) into the **platform** Prometheus (namespace label
  `openshift.io/cluster-monitoring: "true"`; UWM off) — engine down, no targets, L2 headroom,
  eviction pressure, cache-bypass alerts; dashboard shared with monitoring-chart.
- Gateway wiring mirrors glm53: Anthropic backend for quota/accounting + InferencePool rule for
  OpenAI traffic + claude-* alias; `requestTimeout: 900s` (65k-token prefills on L4s run minutes).

### 2.3 `qwen36-judge` 0.2.2 — judge model (independent verdicts)

Renders into `llm-judge`: namespace, SA, SCC, s3-secret, `LLMInferenceService`
`qwen36-judge`, aigatewayroute, openai-backend (7 templates + `_helpers.tpl`/NOTES).
Mission (values header): an independent, always-warm judge for the Claude Code
**PreToolUse hook** (verdicts allow / ask / deny) — a different model family from GLM-5.3 so
the judge is never the agent grading itself. The hook artifacts (client-side `judge.py` +
`judge.json`) ship with the chart.

**Key values**:

| Concern | Value |
|---|---|
| model | `judge`, S3 path `llms/Qwen/Qwen3.6-35B-A3B-FP8` |
| replicas | 1 (`scaling.enabled: false`; planned 1→3 via WVA/KEDA — the enable prerequisites are documented in the values comment); `minReplicas MUST stay 1` (cold start takes minutes) |
| parallelism | TP2 over 2×L4 GPUs on one node (FP8 weights ~35 GB > one 24 GB L4; wider only adds PCIe hops) |
| storage | **no PVC / no pull jobs** — deviation from the glm53 design: kserve `storage-initializer` (`kserve/storage-initializer:v0.21.0-rc1`) pulls `s3://` straight into the pod's emptyDir `/mnt/models` on every pod start |
| vLLM args | `--max-model-len=16384 --max-num-seqs=128` (Mamba/GDN state blocks cap concurrency), `--reasoning-parser=qwen3`, prefix caching, `--enable-prompt-tokens-details --enable-force-include-usage` (gateway billing: cached_tokens + streamed usage metering), thinking off, multimodal refused |
| images | `vllm/vllm-openai:v0.30.0` |

**Design choices**:

- **Two-route design** (README): the AIGatewayRoute carries model-header rules for the serving
  path, plus a separate OpenAI-schema `AIServiceBackend` (`qwen36-judge-openai`) route —
  aigw-ui `QuotaPolicy` can only attach to AIServiceBackends, so the OpenAI route is the quota
  accounting path (live: `QuotaPolicy/judge` in `llm-judge`).
- KServe's own router HTTPRoute also attaches to the shared Gateway (path rules
  `/llm-judge/…`, `/publishers/llm-judge/…`) — same shared-Gateway pattern as glm53.
- `runtimeClassName` / `priorityClassName` deliberately **unset**: the kserve preset merge
  would otherwise inject `node-role.kubernetes.io/roce` selectors the L4 node does not carry.
- The `scaling` block is left disabled: a spec.scaling block without KEDA+WVA makes the
  llmisvc-controller error-loop (verified live per values comment).

### 2.4 `llm-model` 0.2.0 — gateway-side companion chart

For a model **served by another chart** (e.g. the kserve-rendered workload), renders only the
gateway objects: `gateway-route.yaml` (AIGatewayRoute + optional direct AIServiceBackend),
`peer.yaml` (fleet/peers-listener backend objects), `llminferenceservice.yaml` (optional
model creation with aigw-ui capacity annotations), `objectives.yaml` (InferenceObjective),
`alerts.yaml` (PrometheusRule), `namespace.yaml`.

**Key values** (`llm-model/values.yaml`, 178 lines): `gateway.name: envoy-ai-gateway` /
`namespace: envoy-ai-gateway-system`; listeners `client` (http) and `peer` (peers, for the
aigw-ui fleet); `route.direct` (serve via AIServiceBackend instead of the EPP InferencePool
— required for Anthropic passthrough and quota attachment); `internalKey` SecurityPolicy
(API-key auth between gateway and model); traffic split via kserve `router.route` weights;
flowControl (concurrency-detector plugin + maxConcurrency) for queue-aware routing:
`maxConcurrency` counts **per endpoint** (each InferencePool targetPort, one per DP rank),
has no default and is required when flow control is on; `requestTTL` 300s; and
`fairnessPolicy: round-robin-fairness-policy` on the default (and negative) priority band,
so tenants (`x-llm-d-inference-fairness-id`) are served in turn rather than oldest first;
`model.capacityPerInstance` / `maxModelLen` / `revision` annotations consumed by aigw-ui.

**Design rationale** (README): billing/security-policy live on the route (not the workload),
so they can be attached to any server; the fleet (`peer`) path lets aigw-ui serve a model
from a peer site over mTLS; the EPP path cannot parse Anthropic bodies, so direct
AIServiceBackends exist for Claude-protocol models.

### 2.5 `generic-model` 0.1.0 — the consolidation chart

One chart + per-model values profiles that **replace** `glm53-bundled`, `qwen38-bundled` and
`qwen36-judge`: 15 templates (namespace, serviceaccount, scc, s3-secret, node-prep,
local-storage, pull-jobs, llmisvc, lmcache-engine, aigatewayroute, direct-backend,
prometheusrule, monitoring-rbac, aiperf + `_helpers.tpl`). `examples/` contains
`glm53.values.yaml`, `qwen38.values.yaml`, `qwen36-judge.values.yaml` which reproduce the
three original charts' output — the README documents a render-diff oracle
(`helm template` byte-identical) as the acceptance test for the migration, plus a
key-migration table (old chart key → new key).

**Notable**:

- `direct-backend.yaml`: `ranks` style (chart-owned multi-port rank Service + Backend with one
  FQDN endpoint per rank + AIServiceBackend — the EPP-bypass path, quota-attachable) or
  `workload-svc` style (single endpoint on the kserve-owned workload Service).
- Guard templates (`_validate.tpl`) encode the operational invariants discovered on the three
  models: LMCache engine/vLLM image lockstep, chunkSize block-alignment, EP>1 requires
  multi-port external LB, pull-Job specs are immutable (value changes need job deletion —
  hence the qwen38 app's `RespectIgnoreDifferences`).
- Optional blocks mirror the originals: per-chart StorageClass, node-prep (VG/LV/cubin
  seeding), LMCacheEngine, aiperf.

### 2.6 `envoy-ai-gateway-openshift` 0.1.0 (appVersion v1.2.0) — the AI Gateway

Thin OpenShift wrapper that adds the deployment-specific pieces around the **upstream
`ai-gateway-helm` v1.2.0** dependency (Chart.lock; the tgz is extracted in
`upstream-subcharts/ai-gateway-helm-v1.2.0/`). Own templates: `gateway.yaml` (GatewayClass
`envoy-ai-gateway-class`, `Gateway/envoy-ai-gateway`, EnvoyGateway, routes, ClientTrafficPolicy),
`ratelimit.yaml` (ratelimit Deployment + Service + Redis-client Secret + PDB ≥2 replicas),
`peers.yaml` (peers mTLS listener + certificate), `route.yaml`, `health.yaml`,
`scc-rolebinding.yaml` (dataplane SCC), `_validate.tpl` (render-time guards).

**Key values** (`envoy-ai-gateway/values.yaml`, 462 lines):

- Waves: CRDs -10 → SCC -5 → controller 0 → EnvoyGateway 1 → Gateway 2 → routes 3 → ratelimit 5.
- Images: controller/extproc default to upstream `docker.io/envoyproxy/ai-gateway-*`
  (`tag: ""` → appVersion v1.2.0); the **values repo pins a patched build**
  `v1.2.0-patched.1` (controller and extproc from one commit, else they reject each other's
  config — `argocd/operators/envoy-ai/values.yaml`). Ratelimit image
  `envoyproxy/ratelimit:0482748e`.
- Data plane: `envoy:distroless-v1.39.1` digest-pinned (`…@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4`)
  so the mirror holds the exact Docker Hub bits.
- ClientTrafficPolicy `bufferLimit: 50Mi` (upstream basic-usage value, kept).
- Gateway listeners: `http` :80 with `allowedRoutes.from: All`; optional `peers` :8443 mTLS
  (Terminate, Secret `llm-peer-server`, allowedRoutes selector `aigw-ui.io/serving: "true"`)
  — **default off** in the archived values; the live cluster runs it (GITOPS.md §4.4).
- Service overlays: `values-mirror.yaml` (ClusterIP + OpenShift Route, for oc-mirror
  environments) vs `values-loadbalancer.yaml` (LoadBalancer Service + `spec.addresses` VIP);
  the archived operator values use the mirror overlay; the live cluster runs the
  LoadBalancer form (GITOPS.md §4.4).
- ratelimit Redis: default in-cluster `redis.envoy-gateway-system.svc.cluster.local:6379`;
  production overrides to an `existingSecret` + TLS URL pointing at a Route on
  `cluster-hub-prod` (`argocd/sites/…/envoy-ai/values.yaml`).
- `SkipDryRunOnMissingResource` (app-level) because CRDs land in the same sync.

**Upstream subchart** (`ai-gateway-helm` v1.2.0) renders: controller Deployment, admission
webhook, Service, PDB, ServiceAccounts, a ClusterRole granting InferencePool access, and an
mcp-session encryption Secret.

### 2.7 `envoy-gateway-openshift` 0.1.0 (appVersion v1.9.1) — Envoy Gateway control plane

Thin wrapper around **upstream `gateway-helm` v1.9.1** (extracted to
`upstream-subcharts/gateway-helm-v1.9.1/`, including its `crds` subchart). Own pieces:

- `crds/` — 10 CRD manifests (gateway.envoyproxy.io group: Backends, BackendTrafficPolicies,
  ClientTrafficPolicies, EnvoyExtensionPolicies, EnvoyPatchPolicies, EnvoyProxies,
  HTTPRouteFilters, SecurityPolicies; plus `InferencePools` in both
  `inference.networking.k8s.io` and `x-k8s.io`), annotated
  `argocd.argoproj.io/sync-wave: "-10"` and
  `sync-options: ServerSideApply=true,Prune=false,Delete=false` — applied by ArgoCD, never
  pruned. The upstream `crds` subchart is disabled (`crds.enabled: false`): Gateway API CRDs
  are owned by OpenShift/KServe, and this filtered set mirrors what KServe's
  llmisvc-dependency script installs (values comment).
- `templates/scc-rolebinding.yaml` — pre-install hook (Helm hook weight -5 → ArgoCD PreSync
  wave) binding the control plane + certgen to SCC `nonroot-v2` (MustRunAsNonRoot admits the
  upstream images' non-root USER without `anyuid`).
- `EnvoyGateway` config: `extensionApis.enableBackend: true` (AI Gateway Backend CRs),
  `enableEnvoyPatchPolicy: true`; `extensionManager` xDS-translation hooks pointing at
  `ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local` (port 1063) — install
  order: this chart first, then envoy-ai, then restart this Deployment (values comment);
  `backendResources` allows `InferencePool` v1 as backendRef (KServe pools).
- Images: control plane `docker.io/envoyproxy/gateway` — chart default tag `v1.9.1`, pinned
  to `v1.9.2` by `argocd/operators/envoy-gateway/values.yaml` (also the shutdown-manager
  image, a full reference the Go binary reads verbatim). Data-plane Envoy: digest-pinned
  distroless v1.39.1 (same digest as envoy-ai). The overlay pattern matters: the upstream
  helpers split image refs at the first `/` and prepend `imageRegistry`, so mirror paths must
  be given either as `imageRegistry` + upstream-shaped refs or as full refs — never both.
- `deployment.replicas: 1`, resources 256Mi/1024Mi.

**Upstream subchart** (`gateway-helm` v1.9.1) renders: EG Deployment, certgen Job (+RBAC),
topology-injector webhook, HPA, PDB, Service, ServiceAccounts, infra-manager and
leader-election RBAC; its `crds` subchart carries `gatewayapi-safe-upgrade-policy` +
Gateway API CRDs (disabled here).

### 2.8 Charts referenced but not exported

`kserve-chart.git` (KServe controller, CRDs, llm-d scheduler/EPP, cert-manager webhooks) and
`lmcache-chart.git` (LMCache operator + 220–335 KB CRDs). Both are ArgoCD apps on
`cluster-llm-prep` (live evidence: `kserve-deploy`, `lmcache-deploy` tracking-ids); their
chart sources were not collected into `charts/`.

### 2.9 `platform/*` charts (OLM operators + platform plumbing)

All are standalone "Namespace + OperatorGroup + Subscription + CR" wrappers around OLM
operators (except `monitoring`, which deploys plain workloads). Cluster/site layers override
the CR values; image refs for the NVIDIA operands are pinned per-cluster (SHA/tag) in the
site values.

| Chart | Key templates | Key values / notes |
|---|---|---|
| `catalog-sources` 0.1.0 | `catalogsources.yaml` (one CatalogSource per values entry, sync-wave 1) | chart defaults define 3 sources (`cs-operator-index-4.22`, `cs-nvidia-26.3-4.22`, `generic-cs`); the values repo overrides with `generic-cs-certified` + `generic-cs-community` (drift noted in GITOPS.md §3.2) |
| `gpu` 26.3.3 | namespace, operatorgroup, subscription (`gpu-operator-certified.v26.3.3`), cluster-policy, nvidia-driver CRs, clock-lock configmap + daemonset | ClusterPolicy drives the operator; the cluster layer splits NVIDIADriver CRs `roce` (driver 570.148.02) vs `standard`; clock-lock: privileged DaemonSet (hostPID/hostIPC, /dev, host lib64, /run/nvidia) running `chronos.sh` from a ConfigMap to pin GPU clocks (ConfigMap wave 1, DaemonSet wave 5) |
| `network` 26.4.1 | subscriptions (NNO `v26.4.1` OwnNamespace OG; NMO `v26.4.0` AllNamespaces OG), nic-cluster-policy, nic-node-policies, nic-configuration-template | `fabric: roce` scopes all NNO DaemonSets (OFED `doca-driver`, nic-configuration-operator, RDMA shared device plugin `roce_backend` (vendors `15b3`, deviceIDs 1023/1021/101f/101d/101b), NV IPAM) to `node-role.kubernetes.io/roce`; NicConfigurationTemplate `roce` tunes PFC/trust-DSCP, GPU-direct + PCI performance (wave 4); operand images pinned per-cluster |
| `lvms` 4.22.0 | subscription (`lvms-operator.v4.22.0`), lvmcluster | LVMCluster `vg1` (xfs, thin pool 90 %, overprovision 10×); deviceSelector paths + nodeSelector per-cluster |
| `nfd` 4.22.0 | subscription (`nfd.4.22.0-202608042055`), instance | NodeFeatureDiscovery CR; `prunerOnDelete: false` |
| `nmstate-rdma` 4.22.0 | subscription (`kubernetes-nmstate-operator.4.22.0-202608050531`), nmstate CR, nncp-roce, nncp-infiniband | `NMState` CR wave 4 (metrics bindAddress :8089), NNCPs wave 5; RoCE mode: one NNCP per (node, NIC) pinned by hostname with static /31 IPs + optional per-NIC routing tables (deterministic NIC selection, `NCCL_CROSS_NIC=0`); IB mode: per-NIC NNCP on the roce role label; `mode: ""` renders only the operator |
| `numaresources` 4.22.1 | subscription (`numaresources-operator.v4.22.1`), NUMAResourcesOperator CR | cluster-scoped CR (RTE) for NUMA-aware scheduling |
| `istio` 3.4.1 | subscription (`servicemeshoperator3.v3.4.1`, openshift-operators), istio + istiocni CRs | Sail: `Istio`/`IstioCNI` CRs `default` v1.30.3 (istio-system / istio-cni), `updateStrategy: InPlace`; pilot env `ENABLE_GATEWAY_API_INFERENCE_EXTENSION: "true"` |
| `lws` 1.0.0 | subscription (`leader-worker-set.v1.0.0`), LeaderWorkerSetOperator CR | on cluster-llm-prep the app pins `targetRevision: opensource-chart` (GITOPS.md §1.5) |
| `monitoring` 4.2.0 | 4 vendored subcharts, no OLM | `rdma-exporter` 4.2.0: DaemonSet in the DOCA driver image (`doca3.4.1-26.04-192.0.2.1-5-rhel9.8-amd64`), port 9402 `/metrics` + `/aggregate`, nodeSelector `nvidia.com/driver-config: roce`; `hpc-observability` 0.1.6: fabric exporter :9500 (RDMA/ethtool/GPU/PCIe) + node exporter :9501 (CPU/NUMA/NVMe/RAID/PCIe AER), ServiceMonitor 1 s; `prometheus-mcp` 1.1.0: MCP query server (namespace `prometheus-mcp`) against `thanos-querier.openshift-monitoring.svc:9091`; `grafana` 9.2.4: into `openshift-monitoring`, PVC 1Gi on `lvms-vg1`, dashboards shipped as one ConfigMap per JSON (262144-byte last-applied annotation limit) projected into `/var/lib/grafana/dashboards`, s5cmd init image for provisioning; `global.clusterName`/`baseDomain` propagate |

## 3. Chart dependency / relationship map

```
values repo (app-of-apps; GITOPS.md) ── renders one ArgoCD Application per operator
│
├─ platform/catalog-sources ─► CatalogSources ─┬─► platform/gpu, network, nfd,
│                                             │   nmstate-rdma, numaresources,
│                                             │   lvms, istio, lws  (OLM Subscriptions)
│                                             └─► (catalog names: see GITOPS.md §3.2)
├─ platform/monitoring (4 vendored subcharts; scrapes rdma/gpu/node metrics)
│
├─ envoy-gateway-openshift ─► gateway-helm v1.9.1 (+crds subchart, disabled)
│      │   own crds/ (10 CRDs, wave -10, Prune=false): Backends, Policies, InferencePools…
│      │   extensionManager xDS hooks ──────────────┐
│      ▼                                            │
├─ envoy-ai-gateway-openshift ─► ai-gateway-helm v1.2.0
│      │   Gateway/GatewayClass + ratelimit (+Redis) + extProc translation
│      │   needs cert-manager; pins patched controller/extproc v1.2.0-patched.1
│      ▼                                            │
│   shared Gateway `envoy-ai-gateway` ◄────────────┘ (xDS extension)
│
├─ kserve (chart NOT exported): LLMInferenceService API + llm-d EPP scheduler
├─ lmcache (chart NOT exported): LMCacheEngine CRD + operator
│
└─ model charts (helm, per model):
     glm53-bundled / qwen38-bundled / qwen36-judge / generic-model / llm-model
       ├── LLMInferenceService ──► rendered by kserve controller (Deployment, workload
       │                            Service, InferencePool, EPP, router HTTPRoute)
       ├── AIGatewayRoute / AIServiceBackend / Backend ──► attach to the shared Gateway
       ├── LMCacheEngine (qwen38, generic-model) ──► lmcache operator reconciles engine
       ├── node-prep DaemonSet + pull Jobs ──► host LVs/PVs (needs gpu/network/nmstate
       │                                        to have prepared the nodes)
       └── aigw-ui (OUT of git) renders QuotaPolicy / fleet objects against these routes
```

Reading order for a reviewer: envoy-gateway → envoy-ai-gateway → lmcache/kserve → model
charts; catalog-sources and the GPU/network/nmstate trio are prerequisites for the nodes the
model charts land on.

## 4. `glm53-bundled` template-by-template walkthrough (flagship)

Chart root: `charts/glm53-bundled/` — `Chart.yaml` (v0.1.0, appVersion `glm-5.3`),
`values.yaml` (401 lines), `README.md`, `scripts/` (dig, download-model, force-sync,
patch-llm-preset), 11 templates + `_helpers.tpl`. Render order below follows the template
list; sync waves are noted where set.

### 4.1 `namespace.yaml`

Namespace `llm-glm53` with chart labels. No extra labels (unlike qwen38, this chart does not
opt the namespace into platform monitoring; the ServiceMonitors/PrometheusRules seen live in
`llm-glm53` come from kserve-rendered objects).

### 4.2 `serviceaccount.yaml`

ServiceAccount `s3sa` — used by the pull Jobs to read the S3 credentials Secret
(`s3-credentials`, pre-created out-of-band) via a dockercfg/image-pull secret annotation
(the reason the glm53 app config carries `ignoreDifferences` on ServiceAccount
`imagepullsecrets` — the controller mutates it).

### 4.3 `scc.yaml`

SecurityContextConstraints `glm53-model-serving` (modeled on the built-in `anyuid` plus
`allowedCapabilities: [IPC_LOCK]`, `allowPrivilegedContainer: false`, priority 9), plus Role
(`use`) + RoleBinding granting it to the model ServiceAccount — scoped privileges instead of
loosening cluster-wide SCCs.

### 4.4 `s3-secret.yaml`

Optional (`s3Secret.create: false` default) Secret for S3 credentials, so the chart can
render it in greenfield clusters; in the real deployment the Secret is pre-created and only
annotated (annotation guidance in values).

### 4.5 `node-prep.yaml`

The privileged DaemonSet (+ `use-privileged-scc` Role/RoleBinding). Runs `nsenter -t 1` into
the host PID-1 mount namespace and, per LV from values (`llm-models` 1200G, `llm-cache` 300G,
VG `vg1`): `lvcreate` → `mkfs.xfs` → mount at `nodePrep.hostPathBase` → `chcon -R -t
container_file_t`. Because everything happens in the HOST mount namespace, the LVs stay
mounted after the container exits; a 60 s loop re-checks and repairs (idempotent). This is
the workaround for LVMS being thick-LV only.

### 4.6 `local-storage.yaml`

StorageClass `local-static` (no provisioner) + one PV per (node × LV) with
`nodeAffinity` spanning both B200 nodes and `persistentVolumeReclaimPolicy: Retain` + one PVC
per LV pinned to its PV via `volumeName`. Result: fixed local-path storage the pull Jobs and
the LLMInferenceService mount, independent of any scheduler-created volumes.

### 4.7 `pull-jobs.yaml`

One Job per node (`backoffLimit: 3`): runs `s5cmd --endpoint-url … cp` from the S3 bucket
path (`llms/zai-org/GLM-5.3`) into the mounted model LV, touching `.download-complete` as an
idempotency marker (subsequent runs no-op). Job specs are immutable — changing values
requires deleting the Jobs (the drift note in GITOPS.md §4.4).

### 4.8 `llmisvc.yaml`

The core: `LLMInferenceService` `glm53-b200`, `replicas: 2` (one pod per B200 node),
`schedulerName: default-scheduler`, `runtimeClassName:
performance-gpu-hpc-performanceprofile-extras-b200`, `maxSurge: 0`. The kserve base preset
(`kserve-config-llm-template`) runs `vllm serve /mnt/models …` with bash-eval single-token
args; the chart merges:

- parallelism args (DP8/EP8 multi-port external LB + supervisor 8208 — probes point at the
  supervisor),
- memory args (fp8 KV, 0.90 GPU util, 262144 ctx, 64 seqs, 16384 batched tokens, prefix
  caching),
- GLM-5.3 recipe (MTP k=5, `glm47` parsers, tool calls),
- env (offline HF, NCCL single-node NVLink: `NCCL_IB_DISABLE=1`, `NCCL_P2P_LEVEL=NVL`,
  NVSHMEM remote transport off, deep-gemm, persistent JIT caches on the cache PVC),
- resources (8 GPU, 96/192 CPU, 512/2000Gi, 16Gi hugepages, 600Gi dshm),
- `kvCacheOffloading.cpu: 64Gi` (KServe CPU KV-offload connector; the reason v0.29.0
  crash-looped is recorded in the values history note),
- EPP scheduler `config` (EndpointPickerConfig plugin chain + weights) and the full
  `InferencePool` pool spec (`targetPorts` 8000–8007, selector on kserve workload labels,
  `endpointPickerRef` → `glm53-b200-epp-service:9002`, `failureMode: FailOpen`) — copied
  verbatim because with multi-port external LB the controller would not generate the 8 ports
  itself.

### 4.9 `aigatewayroute.yaml`

`AIGatewayRoute` `glm53` (cross-namespace parentRef to the shared `envoy-ai-gateway`
listener `http`). Three rules (first match wins; header `x-ai-eg-model` is derived by the
extProc from the body's `model` field):

1. `glm-5.3` → `AIServiceBackend glm53-anthropic` (Anthropic passthrough; Claude Code
   thinking + count_tokens survive),
2. `publishers/llm-glm53/models/glm-5.3` → `InferencePool glm53-b200-inference-pool` (EPP,
   OpenAI protocol),
3. `^claude-.*$` (regex) → `glm53-anthropic` with `modelNameOverride: glm-5.3`.

Plus `timeouts.request` (raised from the 60 s default — long reasoning) and
`llmRequestCosts` (4 metadata keys: input/output/reasoning/total tokens). With
`anthropicBackend.enabled: false` rule 1 falls back to the InferencePool (translation path).

### 4.10 `anthropic-backend.yaml`

Three objects implementing the EPP bypass:

- Service `glm53-b200-ranks-svc` — chart-owned, ports `rank-0…rank-7` = 8000–8007. Needed
  because the kserve-owned workload Service only declares port 8000 (rank 0); kube-proxy has
  no ClusterIP:8001+ without the ports declared. Additive; kserve ignores it.
- Backend (`anthropicBackend.backendName`) — one FQDN endpoint per (pod × rank port),
  i.e. 16 endpoints round-robin across `glm53-b200-ranks-svc`.
- AIServiceBackend `glm53-anthropic` — `schema: Anthropic`, backendRef → the Backend.

### 4.11 `aiperf.yaml`

Optional benchmark Job (`aiperf.enabled: false` default): runs the aiperf CLI against the
route (model header + tokenizer from the model PVC, output-token profiles), echoing
ARTIFACTS/SUMMARY blocks for capture into CI logs.

### 4.12 `_helpers.tpl`

Labels/name helpers (`glm53.fullname`, `glm53.labels`, selector labels) — standard — and
`glm53.schedulerWithFlowControl`, the scheduler block with flow control added when
`llmisvc.flowControl.enabled` (mirrored as `qwen38.schedulerWithFlowControl`).

**Resulting object set** (~29 objects, per the verification table in
`generic-model/README.md`): 1 namespace, 1 SA, 1 SCC + Role + RoleBinding, 1 optional
Secret, 1 DaemonSet (+2 RBAC), 1 StorageClass + 4 PV + 4 PVC, 2 Jobs, 1 LLMInferenceService
(kserve expands it into Deployment/Services/InferencePool/EPP), 1 AIGatewayRoute, 3
gateway objects (Service/Backend/AIServiceBackend), 1 optional aiperf Job.
