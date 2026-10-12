# LLM Inference Serving Stack — Architecture

Sanitized architecture reference for the GLM-5.3 serving stack on `cluster-llm-prep`
(site `site-a`). Written for a reviewer who has only this archive: the Helm
charts (`charts/`, `gitops/app-of-apps/`, `gitops/platform-repo/`) and live
cluster YAML exports (`live-cluster/ns-*`). Every claim cites a file; facts not
present in those sources are omitted.

Naming conventions used throughout (real identifiers redacted):

| Placeholder | Meaning |
|---|---|
| `cluster-llm-prep` | the OpenShift cluster serving GLM-5.3 (this document's cluster) |
| `cluster-llm-prod`, `cluster-gpu-test`, `cluster-mce-prep`, `cluster-mce-prod` | sibling cluster names used elsewhere in the sanitized export set |
| `site-a` | this cluster's identity in the multi-site "fleet" (`site-b` = the fleet's other site) |
| `registry-internal/` | internal image registry prefix (stripped from image refs) |
| `gpu-node-1`, `gpu-node-2` | the two B200 GPU nodes |
| `util-node-1` | the L4 utility node (EPP, sister models) |
| gateway VIP | the gateway load-balancer VIP — appears as `192.0.2.x` (TEST-NET) addresses in the sanitized exports |
| `peers.llm.example.internal` | the fleet mTLS SNI / peers listener hostname |
| `quota-redis.apps.<hub-cluster>` | fleet quota Redis on the hub cluster |
| `<s3-endpoint>` | the S3 endpoint serving the `llms` bucket |
| `client-1` … `client-7` | per-client quota identities (names redacted) |

Kubernetes in-cluster DNS names (`*.svc.cluster.local`), namespaces, object
names, image tags/digests, ports and resource values are kept verbatim.

Sources by area: GLM-5.3 serving chart `charts/glm53-bundled/` (staged copy of
the `main` branch; the live site runs the newer `bundled` branch — see
`argocd/glm53.yaml`), live cluster state `cluster/ns-llm-glm53/`,
`cluster/ns-envoy-ai-gateway-system/`, `cluster/ns-envoy-gateway-system/`,
`cluster/ns-kserve/`, `cluster/ns-lmcache-operator-system/`, gateway wrapper
charts `charts/envoy-ai-gateway/` and `charts/envoy-gateway/`, upstream
subcharts `charts/upstream-subcharts/`, site values
`argocd/sites/.../envoy-ai/values.yaml`, `platform-repo/`.

---

## 1. Overview

```
                          ┌──────────────────────────────────────────────────────────────┐
                          │                        CLIENTS                                │
                          │  OpenAI SDK  ·  Claude Code (/anthropic)  ·  curl scripts    │
                          └───────────────┬──────────────────────────────────────────────┘
                                          │ https (edge TLS, Redirect)
                                          ▼
                          ┌──────────────────────────────────────────────────────────────┐
                          │ OpenShift Route envoy-ai-gateway                              │
                          │ host: envoy-ai-gateway-envoy-gateway-system.apps.<cluster-domain>│
                          │ to: Service/envoy-ai-gateway → targetPort http-80              │
                          │ (cluster/ns-envoy-gateway-system/routes_route_openshift_io.yaml)│
                          └───────────────┬──────────────────────────────────────────────┘
                                          │ (Service type LoadBalancer, gateway VIP)
                                          ▼
   ┌───────────────────────────────────────────────────────────────────────────────────────────┐
   │ Gateway envoy-ai-gateway (ns envoy-ai-gateway-system, GatewayClass envoy-ai-gateway)     │
   │                                                                                           │
   │ listener "http"  :80  HTTP  ─── routes: fleet-glm-5-3, glm53, glm53-anthropic-alias,      │
   │                                        glm53-b200-kserve-route, health, quota, metrics…   │
   │ listener "peers" :8443 HTTPS Terminate, TLS from Secret envoy-ai-gateway-server-cert,      │
   │                   routes selected by label aigw-ui.io/serving: "true"                     │
   │                   routes: glm53-peer (→InferencePool), glm53-peer-health                  │
   │                                                                                           │
   │ EnvoyProxy: 3 envoy replicas, envoy:distroless-v1.39.1@sha256:eb2c01c1…, PDB minAvailable 1│
   │ ext_proc sidecar: ai-gateway-extproc:v1.2.0-patched.1 (injected) — model rewrite,         │
   │ token usage extraction, quota hooks. Controller ai-gateway-controller:v1.2.0-patched.1.  │
   └──────┬───────────────────────────────────────┬──────────────────────────────────────────┘
          │                                       │
          │ (a) FLEET PATH (OpenAI schema)        │ (b) ANTHROPIC PATH (passthrough)
          │ x-ai-eg-model: glm-5.3 (Exact)        │ x-ai-eg-model: ^claude-.*$   OR
          │                                       │ x-ai-eg-model: glm-5.3 + anthropic-version: .+
          ▼                                       ▼
   AIGatewayRoute fleet-glm-5-3              AIGatewayRoute glm53 (claude-alias rule) +
        │                                    AIGatewayRoute glm53-anthropic-alias
        ▼                                              │
   AIServiceBackend fleet-glm-5-3                       ▼
   (schema OpenAI; bodyMutation                      AIServiceBackend glm53-anthropic
    removes kv_transfer_params)                     (schema Anthropic, modelNameOverride glm-5.3)
        │                                              │
        ▼                                              ▼
   Backend fleet-glm-5-3                            Backend glm53-ranks
   1 endpoint: envoy-ai-gateway                     8 FQDN endpoints
   .envoy-gateway-system.svc.cluster.local:8443     glm53-b200-ranks-svc.llm-glm53
   zone site-a, TLS: fleet CA + client cert,        .svc.cluster.local:8000…8007
   SNI peers.llm.example.internal                 (plain LB, no session affinity,
        │                                            no EPP, no circuit breaker)
        │  HAIRPIN: back into the same gateway's peers listener
        ▼
   peers listener :8443 (mTLS client validation, requestID preserved, late
        response header x-llm-served-by: site-a)
        │
        ▼
   AIGatewayRoute glm53-peer (header x-ai-eg-model glm-5.3)
        │
        ▼
   InferencePool glm53-b200-inference-pool (failMode FailOpen)
   targetPorts 8000-8007 · endpointPickerRef Service glm53-b200-epp-service:9002
        │
        ▼
   EPP Deployment glm53-b200-kserve-router-scheduler
   (llm-d-router-endpoint-picker v0.10.0, 1 replica, Recreate)
   plugins: single-profile-handler, approx-prefix-cache-producer,
            inflight-load-producer, prefix-cache-scorer (w3),
            active-request-scorer (w3), token-load-scorer (w1), max-score-picker
        │  picks a single rank pod:port
        ▼
   ┌───────────────────────────────────────────────────────────────────────────┐
   │ Deployment glm53-b200-kserve (KServe LLMInferenceService glm53-b200)     │
   │ 2 pods, one per B200 node. Each pod: 8× B200, vLLM DP=8 → 8 API servers   │
   │ listening on container ports 8000-8007                                   │
   │ rank Services: kserve workload svc :8000 + chart svc glm53-b200-ranks-svc │
   │ :8000-8007 (cluster/ns-llm-glm53/services.yaml)                          │
   └───────────────────────────────────────────────────────────────────────────┘
```

Parallel data path (same gateway, `http` listener): the KServe router
HTTPRoute `glm53-b200-kserve-route` exposes path-based URLs
(`/llm-glm53/glm53-b200/v1/...`, `/publishers/llm-glm53/models/glm-5.3/...`)
for in-cluster consumers, protected by SecurityPolicy
`glm53-b200-kserve-route-internal` (apiKeyAuth, Secret `glm53-internal-key`)
(`cluster/ns-llm-glm53/httproutes_gateway_networking_k8s_io.yaml`,
`cluster/ns-llm-glm53/securitypolicies_gateway_envoyproxy_io.yaml`).

Every AI Gateway path passes through the ext_proc sidecar for model-header
rewrite and token accounting, and quota enforcement via the ratelimit service
`envoy-ai-gateway-ratelimit` (envoyproxy/ratelimit:0482748e, xDS-configured by
the controller, Redis-backed) — see §8.

Traffic flow summary for one OpenAI-protocol request: client → Route (TLS
offload) → `http` listener → AIGatewayRoute `fleet-glm-5-3` → extproc rewrites
model to a fully-qualified backend name → Backend hairpins to `peers` listener
over fleet mTLS → AIGatewayRoute `glm53-peer` → InferencePool → EPP picks the
best rank pod:port (prefix-cache-aware) → vLLM. Anthropic-schema requests skip
the hairpin and EPP entirely and load-balance across all 16 rank endpoints of
both pods.

---

## 2. Hardware and nodes

Three RHEL/OpenShift nodes run the stack (names in this doc: `gpu-node-1`,
`gpu-node-2`, `util-node-1`). Sizes are encoded in the real hostnames and
described in the chart READMEs:

| Node | Hardware | GPUs | RAM | Cores | Data disk | Role |
|---|---|---|---|---|---|---|
| `gpu-node-1` | Dell XE9780 | 8× NVIDIA B200 | 2048 GiB | 256 | 9 TB (→ VG `vg1`) | glm53 inference pod + LMCache MP server + node-prep |
| `gpu-node-2` | Dell XE9780 | 8× NVIDIA B200 | 2048 GiB | 256 | 9 TB (→ VG `vg1`) | glm53 inference pod + LMCache MP server + node-prep |
| `util-node-1` | Dell R760xa | 8× NVIDIA L4 | 512 GiB (~439 Gi allocatable) | 144 | 5 TB | EPP router-scheduler, qwen38 model, judge model, envoy data plane, controllers |

Sources: hostnames in `cluster/ns-llm-glm53/persistentvolumeclaims.yaml` and
`cluster/ns-llm-glm53/jobs_batch.yaml` embed the `256c-2048gb-9tb` /
`144c-512gb-5tb` specs; L4 node shape ("one NVIDIA-L4 R760xa, 8 GPUs / 128 CPU
/ ~439Gi allocatable RAM / one blank 1.7T data disk") from
`charts/qwen38-bundled/README.md`; Dell model names from the node-prep
comments in `charts/glm53-bundled/templates/node-prep.yaml`.

Node-level details that matter:

- **GPU nodes are single-tenant for this workload**: both B200 nodes carry the
  full 2048 GiB as one LVM volume group `vg1`, carved into three logical
  volumes by the node-prep DaemonSet (§6). The glm53 pod requests 512 Gi and
  limits 2000 Gi memory — the node is sized for one inference pod plus its
  LMCache tier-1 RAM allocation (`charts/glm53-bundled/values.yaml`).
- `vg1` is built day-1 from `/dev/md/lvmdata` (host RAID) on fresh nodes; the
  chart can also create it from blank data disks when absent
  (`charts/glm53-bundled/templates/node-prep.yaml`,
  `charts/qwen38-bundled/values.yaml`).
- **Scheduling**: inference pods select
  `nodeSelector: nvidia.com/gpu.product: NVIDIA-B200`; qwen38/judge select
  `NVIDIA-L4`. The glm53 pods run under `runtimeClassName:
  performance-gpu-hpc-performanceprofile-extras-b200` (TuningDone/PerformanceProfile
  extras) with `priorityClassName: openshift-user-critical`
  (`cluster/ns-llm-glm53/deployments_apps.yaml`).
- The two glm53 pods are pinned one-per-node in practice by resource limits
  (8 GPU request per pod, 8 GPUs per node). Pod names in
  `cluster/ns-llm-glm53/endpointslices_discovery_k8s_io.yaml` show one workload
  pod per B200 node, plus the EPP pod and the utility models on
  `util-node-1`.

## 3. The model: GLM-5.3

**Live deployment serves `GLM-5.3-Flash-NVFP4`** (RedHatAI NVFP4 build with a
separate MTP head), pulled from `s3://llms/RedHatAI/GLM-5.3-Flash-NVFP4`
(`cluster/ns-llm-glm53/jobs_batch.yaml`), mounted read-only from PVC
`glm53-models` with `subPath: GLM-5.3-Flash-NVFP4`; the LLMInferenceService
spec uses `uri: pvc://glm53-models/GLM-5.3-Flash-NVFP4`
(`cluster/ns-llm-glm53/llminferenceservices_serving_kserve_io.yaml`). The set
includes `model_mtp.safetensors` plus its index (weights for multi-token
prediction) alongside the main shards and
`model.safetensors.index.json`.

The staged chart (`charts/glm53-bundled/`, `main` branch) predates the swap and
still references the original `s3://llms/zai-org/GLM-5.3`, described in its
README as an "FP8 MoE, 564G" checkpoint. The live site runs the newer `bundled`
branch (`argocd/glm53.yaml`, `bundled` ref with the vLLM billing flags of
2026-10-12), which is what the live YAML reflects. Where the two disagree, this
document follows the **live cluster YAML**.

**Architecture (from chart commentary — the export contains no model config
JSON)**: GLM-5.3 is a Mixture-of-Experts model using "MLA plus its DSA
indexer" with "hybrid KV layouts" (vLLM `GlmMoeDsa` implementation), i.e. the
DeepSeek-style sparse-attention indexer on top of multi-head latent attention.
This is why the chart pins `chunkSizeModulus` for LMCache to 64 — GLM-5.3's
token block size (`charts/glm53-bundled/values.yaml`, kv-cache-offloading and
lmcache sections). Both server-side KV (fp8, see §4) and the attention
structure constrain the cache tooling in §5.

Served model names (both resolve to the same weights):

| Name | Used by |
|---|---|
| `glm-5.3` | gateway model-header routing (`x-ai-eg-model`), Anthropic backend override |
| `publishers/llm-glm53/models/glm-5.3` | fleet/KServe-router clients, publishers convention |

(`--served-model-name glm-5.3 publishers/llm-glm53/models/glm-5.3` in
`cluster/ns-llm-glm53/deployments_apps.yaml`.)

Quantization: NVFP4 on disk (the Flash build). KV cache is fp8 at runtime
(`--kv-cache-dtype=fp8`, §4). The contract for this document mentioned
"704GB bf16, 141 safetensors" and specific config keys (`index_n_heads`,
`index_topk`, `hidden_size 6144`, `head_dim 192`, `first_k_dense_replace 3`) —
**none of these appear anywhere in the archive**; they are omitted rather than
guessed.

---

## 4. Serving layer: KServe LLMInferenceService → vLLM

### 4.1 Control chain

`LLMInferenceService glm53-b200` (`serving.kserve.io/v1alpha2`, ns
`llm-glm53`) is reconciled by the KServe **llmisvc-controller**
(`kserve/llmisvc-controller:v0.21.0-rc1`, ns `kserve`,
`cluster/ns-kserve/deployments_apps.yaml`) into Deployment
`glm53-b200-kserve` (2 replicas) plus a workload Service
(`glm53-b200-kserve-workload-svc`, port 8000) and router objects
(`cluster/ns-llm-glm53/llminferenceservices_serving_kserve_io.yaml`,
`cluster/ns-llm-glm53/deployments_apps.yaml`). The spec embeds a vLLM preset
with a bash launcher: it version-detects vLLM to pick flag compatibility, sets
a 280 s shutdown timeout, and falls back to an `OffloadingConnector`
kv-transfer-config only when the user did not pass one
(`charts/upstream-subcharts/` preset logic mirrored in the live deployment's
command; the glm53 chart passes `--kv-transfer-config` explicitly, so the
fallback is inert here).

| Object | Value |
|---|---|
| Deployment | `glm53-b200-kserve`, 2 replicas, strategy RollingUpdate maxSurge 0 / maxUnavailable 1 |
| Pod | `terminationGracePeriodSeconds: 300`, `preStop: sleep 15`, SA `s3sa`, `runtimeClassName: performance-gpu-hpc-performanceprofile-extras-b200`, `priorityClassName: openshift-user-critical` |
| Image | `vllm-openai@sha256:464346c43ec233f5ddee4eab563107289b442dc6174594efcc1f0762a6e5b882` (registry prefix stripped; digest-pinned; the export shows no version tag — the chart family is the vLLM 0.29–0.30 era, `charts/glm53-bundled/values.yaml` images section) |
| Resources | requests: cpu 96, memory 512Gi, gpu 8, hugepages-1Gi 16Gi · limits: cpu 192, memory 2000Gi, gpu 8, hugepages-1Gi 16Gi |
| Volumes | `kserve-pvc-source` = PVC `glm53-models` subPath `GLM-5.3-Flash-NVFP4` (readOnly) · `compile-cache` = PVC `glm53-cache` · `dshm` = 600Gi Memory emptyDir (DP/B200 shared memory) · `hugepages` 16Gi · `tls-certs` (self-signed) · `model-cache`,`home`,`tmp-dir` emptyDirs |

The 600 Gi `/dev/shm` and 2000 Gi memory limit are deliberate: with DP=8 the
vLLM data-parallel workers share NCCL/NVSHMEM buffers through POSIX shm, and
the staged chart's commentary budgets ~8×64 Gi = 512 Gi for DP comms alone
(`charts/glm53-bundled/values.yaml`).

### 4.2 vLLM arguments (live deployment, ground truth)

From `cluster/ns-llm-glm53/deployments_apps.yaml` (container args; the staged
chart at `charts/glm53-bundled/values.yaml` shows an older flag set — live
wins):

| Flag | Value | What it does |
|---|---|---|
| `--data-parallel-size` | 8 | 8 data-parallel replicas of the engine inside one pod — one API server per rank, over the pod's 8 B200s |
| `--data-parallel-size-local` | 8 | all 8 DP ranks are local to this pod (no cross-pod DP) |
| `--data-parallel-multi-port-external-lb` | — | each DP rank serves its own HTTP port 8000–8007 and expects an external LB to spread requests across ranks (chart commentary: vLLM's internal DP balancer measurably double-loads ranks — rank 3 saw 2/5 requests in a 5-request test) |
| `--data-parallel-supervisor-port` | 8208 | DP supervisor's control port; also the target of the pod's HTTP probes |
| `--enable-expert-parallel` | — | MoE experts sharded across GPUs (EP) rather than replicated |
| `--all2all-backend` | `allgather_reducescatter` | NCCL all2all algorithm for expert dispatch/combine |
| `--kv-cache-dtype` | `fp8` | KV cache stored as fp8 (halves KV bytes vs fp16/bf16) |
| `--gpu-memory-utilization` | 0.85 | fraction of each B200's HBM vLLM may claim |
| `--max-model-len` | 262144 | 256k-token context |
| `--max-num-seqs` | 512 | max concurrent sequences per rank |
| `--max-num-batched-tokens` | 32768 | prefill batch budget per step |
| `--enable-prefix-caching` | — | reuse KV for shared prompt prefixes (agent traffic is highly prefix-heavy) |
| `--enable-chunked-prefill` | — | interleave prefill chunks with decode; keeps TTFT sane under load |
| `--load-format` | `auto` | standard weight loader |
| `--speculative-config.method` | `mtp` | use the model's native multi-token-prediction head for speculative decoding |
| `--speculative-config.num_speculative_tokens` | 3 | 3 draft tokens per step |
| `--reasoning-parser` | `glm45` | parse `<think>`-style reasoning blocks for the OpenAI `reasoning` field |
| `--tool-call-parser` | `glm47` | parse GLM tool-call syntax from the model output |
| `--enable-auto-tool-choice` | — | let the server pick tools automatically when the model emits calls |
| `--per-request-spec-decode-metrics=summary` | — | emit aggregate speculative-decoding metrics (accepted/rejected draft tokens) |
| `--kv-cache-metrics` | — | export KV cache hit/usage metrics |
| `--enable-prompt-tokens-details` | — | report `cached_tokens` in usage — feeds the quota cost formula (§8) |
| `--enable-force-include-usage` | — | always include the usage block, including on SSE streams (the "billing flags", added 2026-10-12 per `argocd/glm53.yaml`) |
| `--trust-remote-code` | — | required for GLM custom model code |
| `--kv-transfer-config` | JSON (below) | wire KV-transfer to the LMCache MP server (§5) |

`--kv-transfer-config` (verbatim structure):

```json
{"kv_connector":"LMCacheMPConnector",
 "kv_connector_extra_config":{"lmcache.mp.host":"tcp://glm53-cache.llm-glm53.svc.cluster.local",
                              "lmcache.mp.isolated_ipc":true,
                              "lmcache.mp.port":"5555"},
 "kv_connector_module_path":"lmcache.integration.vllm.lmcache_mp_connector",
 "kv_role":"kv_both"}
```

The pod also publishes the same object as ConfigMap
`glm53-cache-connection` for consumers
(`cluster/ns-llm-glm53/configmaps.yaml`).

### 4.3 Environment (every variable)

| Variable | Value | Meaning |
|---|---|---|
| `DG_JIT_CACHE_DIR` | `/cache/deep_gemm` | DeepGEMM JIT kernel cache location (on the cache LV) |
| `FLASHINFER_WORKSPACE_BASE` | `/cache/flashinfer` | flashinfer workspace; the seeded cubins land under its `.cache/flashinfer/cubins` (§6) |
| `HF_HOME` / `HF_HUB_CACHE` | `/cache/hf` / `/models` | HF cache roots (weights come from the PVC, nothing is downloaded) |
| `HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE` | `1` | never touch the internet (air-gapped) |
| `HOME` | `/home` | writable HOME on an emptyDir (vLLM writes dotfiles) |
| `NCCL_IB_DISABLE` | `1` | disable InfiniBand in NCCL — the RoCE HPC profile handles fabric; avoids double-IB attempts on nodes without IB |
| `NCCL_P2P_LEVEL` | `NVL` | cap peer-to-peer at the NVLink domain (8 GPUs in one NVLink domain per node) |
| `NVSHMEM_IB_ENABLE_IBGDA` | `0` | disable NVSHMEM IB GDA (GPU-Direct Async) — same fabric reasoning |
| `NVSHMEM_REMOTE_TRANSPORT` | `none` | no cross-node NVSHMEM: each pod's DP group stays inside its node |
| `OMP_NUM_THREADS` | `16` | CPU OpenMP threads per process |
| `PYTHONHASHSEED` | `0` | deterministic hashing (reproducible behavior across restarts) |
| `TORCHINDUCTOR_CACHE_DIR` | `/cache/inductor` | torchinductor compile cache on the LV |
| `TORCHINDUCTOR_FX_GRAPH_CACHE` | `1` | persist FX graph compiles (faster cold start) |
| `TRITON_CACHE_DIR` | `/cache/triton` | triton kernel cache on the LV |
| `VLLM_CACHE_ROOT` | `/cache/vllm` | vLLM compilation/misc cache root |
| `VLLM_DEEP_GEMM_WARMUP` | `skip` | do not run DeepGEMM warmup at boot (air-gap + cubins pre-seeded) |
| `VLLM_ENGINE_READY_TIMEOUT_S` | `3600` | engine startup budget — cold first boot loads/compiles for a long time (chart README: ~15–20 min per pod) |
| `VLLM_LOGGING_LEVEL` | `INFO` | server log level |
| `VLLM_USE_DEEP_GEMM` | `1` | use DeepGEMM kernels for fp8 GEMMs |
| `VLLM_USE_V1` | `1` | vLLM V1 engine |

All from `cluster/ns-llm-glm53/deployments_apps.yaml`; the `NCCL_*`/`NVSHMEM_*`
rationale ("KSERVE_INFER_ROCE" preset context) is documented in
`charts/glm53-bundled/values.yaml` (env block commentary).

### 4.4 Ports, probes, and benchmarking color

- **Ports**: 8000–8007 = per-rank vLLM API servers; 8208 = DP supervisor
  (probes + graceful shutdown). Probes: startup `GET /health:8208`
  (period 10 s, failureThreshold 180 → 30 min budget), readiness
  `GET /readyz:8208` (10 s × 5), liveness `GET /health:8208` (30 s × 5)
  (`cluster/ns-llm-glm53/deployments_apps.yaml`).
- **Blast-throughput evidence**: ConfigMap `glm53-100k-script`
  (`cluster/ns-llm-glm53/configmaps.yaml`) is a load-test harness driving 100
  concurrent 100k-token distinct prompts; its commentary expects ~96 in-flight
  requests, KV-bound at 6 running per DP rank × 16 ranks — the sizing
  rationale for max-num-seqs 512 and the cache tiers.

---

## 5. LMCache: cross-pod KV cache tiers

Managed by the **lmcache-operator** (`lmcache/lmcache-operator:v0.5.5`, ns
`lmcache-operator-system`, `cluster/ns-lmcache-operator-system/deployments_apps.yaml`).
The engine for GLM-5.3 is `LMCacheEngine glm53-cache` (ns `llm-glm53`,
`cluster/ns-llm-glm53/lmcacheengines_lmcache_lmcache_ai.yaml`), rendered as a
DaemonSet (one MP-server pod per B200 node, both Ready) running
`lmcache/lmcache/vllm-openai:v0.5.5` (lmcache 0.5.5 + vLLM 0.29.0 per
`charts/qwen38-bundled/README.md` — engine image must stay in lockstep with
the serving image's lmcache build: the two sides speak a private
ZMQ/CUDA-IPC protocol).

| Setting | Value | Meaning |
|---|---|---|
| MP server | port `5555` (ZMQ), http 8080 (metrics) | `tcp://glm53-cache.llm-glm53.svc.cluster.local:5555`; vLLM pods connect as `kv_both` producers/consumers (§4.2) |
| `isolatedIPC` | true | the engine's CUDA-IPC domain is isolated from vLLM's (avoids IPC handle collisions) |
| `hostIPC` / `hostNetwork` | false / false | namespaced, no host access |
| Priority | `openshift-user-critical` | never evicted under node pressure |
| `--separate-object-groups` | — | the GLM recipe: hybrid-attention (MLA+DSA) models use separate object groups per KV layout |
| chunkSize | 256 | KV stored in 256-token chunks (GLM-5.3 requires a multiple of its 64-token block size) |
| hash | blake3 | fast content hash for chunk keys |
| maxWorkers | 8 | background worker threads |
| Tier 1 | RAM, 1000 Gi | process-local RAM cache with LRU eviction (watermark 0.8, evict-to ratio 0.2) |
| Tier 2 | `nixl_store_dynamic` POSIX backend at `/mnt/lmcache-l2`, max_capacity_gb 2200, shard_dirs, no direct I/O, `persist_enabled: true` | node-local NVMe (LV `llm-l2`, §6) surviving pod restarts |
| Tier 2 eviction | LRU, watermark 0.9, evict-to ratio 0.1 | |
| Resources | requests cpu 4 / memory 1005Gi; limits memory 1508Gi | |
| Volume | PVC `glm53-cache-l2` (2500Gi, local-static) | |

Probes on the MP server: TCP 5555 (startup failureThreshold 200 × 5 s; readiness
5 s; liveness 10 s) — the engine must tolerate the vLLM pod's 30-minute cold
start without flapping.

Why it exists (`charts/glm53-bundled/values.yaml`, kv-cache-offloading
commentary): agent traffic re-sends the same long system/tool prompts every
turn; a 100k-token prefill costs ~26 s of GPU time. With prefix caching
cross-pod and cross-restart (T1 RAM, T2 NVMe), re-sent prefixes hit a tier
instead of re-prefilling. The tiers are also what make preemption recovery and
rolling deploys cheap: a restarted pod re-attaches to surviving KV.

Operational note from the chart: LMCache chunk size must stay a multiple of 64
for GLM-5.3 (`chunkSizeModulus`); a mismatch silently degrades to no caching.

## 6. Storage and node preparation

### 6.1 Local static PVs

No dynamic provisioner for the hot paths. StorageClass `local-static`
(provisioner `kubernetes.io/no-provisioner`, `WaitForFirstConsumer`,
`reclaimPolicy: Retain`) with pre-created PVs whose nodeAffinity lists **both**
B200 nodes and whose PVCs pin `volumeName` (`charts/glm53-bundled/templates/local-storage.yaml`,
`cluster/ns-llm-glm53/persistentvolumeclaims.yaml`):

| Claim | Size | Backing LV | Mount in pods |
|---|---|---|---|
| `glm53-models` | 1200Gi | `llm-models` | `/mnt/models` (read-only, subPath GLM-5.3-Flash-NVFP4) |
| `glm53-cache` | 300Gi | `llm-cache` | `/cache` (compile/cubin caches) |
| `glm53-cache-l2` | 2500Gi | `llm-l2` | `/mnt/lmcache-l2` (LMCache T2) |

One PV across two nodes works because each node holds its own copy of the data
on identically-named paths; the single-Deployment/two-replica pod template mounts
whichever node it lands on. (A pre-existing 1Ti `glm53-model` PVC on
LVMS/topolvm is legacy, superseded by this scheme.)

### 6.2 node-prep DaemonSet

`glm53-node-prep` (`cluster/ns-llm-glm53/daemonsets_apps.yaml`, template
`charts/glm53-bundled/templates/node-prep.yaml`) is **privileged** (`nsenter
-t 1 -m -u -i -n`, hostPID) and idempotently (60 s loop) prepares each GPU
node:

1. Creates LVs on VG `vg1` (from day-1 `/dev/md/lvmdata`): `llm-models` 1200G,
   `llm-cache` 300G, `llm-l2` 2500G — XFS formatted.
2. Mounts each LV at `/var/mnt/llm/{models,cache,lmcache-l2}` **and** at the
   ostree canonical path: RHCOS `/var` is a bind of
   `<rootfs>/ostree/deploy/rhcos/var`, so both resolutions must land on the LV
   or container mounts silently hit the boot disk instead.
3. Writes matching `fstab` entries (`xfs defaults,nofail,
   x-systemd.device-timeout=10s`) so LVs survive node reboots.
4. `chcon -R -t container_file_t` SELinux relabel of the LV roots (plus
   `chmod 1777` on the cache dir) so unprivileged pods can read/write.

### 6.3 flashinfer cubin seeding (air-gap requirement)

vLLM's flashinfer would fetch trtllm-gen cubins from
`edge.urm.nvidia.com` at runtime — unreachable air-gapped. node-prep instead
runs a sidecar `cubin-src` (image `vllm-openai:v0.30.0`, whose flashinfer
0.6.18.post1 **bundles** the cubins; the lmcache image ships plain 0.6.18
without them), greps its PID via `/proc`, and copies
`/proc/<pid>/root/usr/local/lib/python3.12/dist-packages/flashinfer_cubin/cubins`
into the cache LV under `.../flashinfer/.cache/flashinfer/cubins`. flashinfer
checks `FLASHINFER_CUBIN_DIR` first and sha256-verifies each cubin — seeding is
idempotent and makes first-token after cold boot deterministic
(`charts/glm53-bundled/templates/node-prep.yaml` and
`charts/qwen38-bundled/values.yaml` nodePrep comments).

### 6.4 S3 model pull Jobs

Per-node Jobs `glm53-pull-flash-<node>` (template
`charts/glm53-bundled/templates/pull-jobs.yaml`, live instances in
`cluster/ns-llm-glm53/jobs_batch.yaml`) mirror
`s3://llms/RedHatAI/GLM-5.3-Flash-NVFP4/*` into the models LV with
`s5cmd --concurrency 128 --part-size 256`, then verify every shard referenced by
`model.safetensors.index.json` exists locally (verify-index) and drop a
`.download-complete` marker that node-prep/gating checks. Resources scale 16→48
CPU / 32→100Gi for the copy window. Credentials come from the `s3sa` SA's
linked Secret (endpoint annotation carries the plain-`http://` scheme for the
internal `<s3-endpoint>`).

---

## 7. Envoy AI Gateway

### 7.1 Control plane

| Component | Version / shape | Source |
|---|---|---|
| Envoy Gateway (Gateway API impl) | controller `envoyproxy/gateway:v1.9.2`, 1 replica; wrapper chart `envoy-gateway-openshift` over upstream `gateway-helm` v1.9.1 with `crds.enabled=false` (OpenShift ingress-operator owns Gateway API CRDs, v1.4.1) | `cluster/ns-envoy-gateway-system/deployments_apps.yaml`, `charts/envoy-gateway/values.yaml` |
| Envoy AI Gateway (aigw controller) | `ai-gateway-controller:v1.2.0-patched.1` (internal patched build), 1 replica, leader election; injects the ext_proc sidecar into envoy dataplane pods | `cluster/ns-envoy-ai-gateway-system/deployments_apps.yaml` |
| ext_proc sidecar | `ai-gateway-extproc:v1.2.0-patched.1` — per-request model rewrite, schema handling, token-usage extraction, quota hooks | same |
| Dataplane | Deployment `envoy-envoy-ai-gateway-system-envoy-ai-gateway-04213612`, **3 replicas**, `envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c1…`, PDB minAvailable 1, resources 100m/256Mi → 1024Mi | same |
| Ratelimit | `envoy-ai-gateway-ratelimit`, 1 replica, `envoyproxy/ratelimit:0482748e`, gRPC :8081, limits via xDS from the controller :18002, Redis (TLS) as shared state | `charts/envoy-ai-gateway/templates/ratelimit.yaml`, live deployment in ns `envoy-gateway-system` |

Controller flags that shape behavior
(`cluster/ns-envoy-ai-gateway-system/deployments_apps.yaml`):

| Flag | Value | Meaning |
|---|---|---|
| `--endpointPrefixes` | `openai:,cohere:/cohere,anthropic:/anthropic,typesafe:/typesafe` | path-prefix per protocol family — **the /anthropic prefix convention**: Anthropic-schema clients hit `http://192.0.2.127/anthropic/v1/messages` (the gateway VIP; TEST-NET stand-in address) — set clients' `ANTHROPIC_BASE_URL` to that |
| `--quotaRateLimitServiceAddr` | `envoy-ai-gateway-ratelimit.envoy-gateway-system` | quota checks go to the ratelimit service |
| `--quotaRateLimitTimeout` | 5 | seconds before quota RPC gives up |
| `--quotaRateLimitFailureModeDeny` | `false` | **quota outage fails open** (requests pass) |

Gateway object: `envoy-ai-gateway` (ns `envoy-ai-gateway-system`), GatewayClass
`envoy-ai-gateway` → EnvoyGateway CR → EnvoyProxy CR (3 replicas, Service type
LoadBalancer with `externalTrafficPolicy: Local`, address = the gateway VIP
(192.0.2.x in the sanitized exports)).

| Listener | Port/protocol | Route admission |
|---|---|---|
| `http` | :80 HTTP | all namespaces (8 attached routes) |
| `peers` | :8443 HTTPS Terminate (cert from Secret `envoy-ai-gateway-server-cert`) | routes labeled `aigw-ui.io/serving: "true"` (2 attached) — fleet peers only |

(`cluster/ns-envoy-ai-gateway-system/gateways_gateway_networking_k8s_io.yaml`,
`.../envoyproxies_gateway_envoyproxy_io.yaml`.)

### 7.2 Fleet data plane (OpenAI protocol → EPP)

Everything on this path is driven by `aigw-ui` (the fleet's gateway-manager
UI), which writes the objects it manages; see §8 for its API-key and quota
objects.

1. **AIGatewayRoute `fleet-glm-5-3`** (ns `envoy-ai-gateway-system`, `http`
   listener): header match `x-ai-eg-model = glm-5.3` (Exact) →
   **AIServiceBackend `fleet-glm-5-3`** (schema OpenAI; bodyMutation filter
   removes the `kv_transfer_params` body field so clients can't steer KV
   placement).
2. → **Backend `fleet-glm-5-3`**: exactly one FQDN endpoint
   `envoy-ai-gateway.envoy-gateway-system.svc.cluster.local:8443`, zone
   `site-a`, TLS with fleet CA (ConfigMap `llm-peer-ca`), client cert
   `llm-peer-client`, SNI `peers.llm.example.internal`,
   `insecureSkipVerify: false`. **This hairpins the request back into the same
   gateway's `peers` listener** — the mechanism that makes one site's gateway a
   fleet edge: the peers listener is where other sites (or this site) hand off
   with mTLS.
3. On the `peers` listener, **AIGatewayRoute `glm53-peer`**
   (`cluster/ns-envoy-ai-gateway-system/aigatewayroutes_aigateway_envoyproxy_io.yaml`,
   label-selected): header `x-ai-eg-model = glm-5.3` →
   **InferencePool `glm53-b200-inference-pool`**.
4. **InferencePool** (`cluster/ns-llm-glm53/inferencepools_inference_networking_k8s_io.yaml`):
   selector `app: glm53-b200-kserve`, **targetPorts 8000–8007** (the 8 DP-rank
   ports), `failureMode: FailOpen`, and `endpointPickerRef` → Service
   `glm53-b200-epp-service:9002`. Envoy Gateway offloads endpoint selection
   to the EPP over gRPC; `FailOpen` means if the EPP is unreachable Envoy
   falls back to plain load balancing instead of 503-ing.
5. **EPP: Deployment `glm53-b200-kserve-router-scheduler`** — image
   `llm-d-router-endpoint-picker:v0.10.0`, 1 replica, strategy **Recreate**
   (`cluster/ns-llm-glm53/deployments_apps.yaml`). Ports 9002 (gRPC ext-proc
   selection), 9003 (gRPC health), 9090 (metrics), 5557 (zmq profile
   exchange). Plugins, in order:

| Plugin | Role | Scheduler weight |
|---|---|---|
| `single-profile-handler` | profile extraction from request | — |
| `approx-prefix-cache-producer` | hashes approximate prompt prefixes from the request body | — |
| `inflight-load-producer` | counts requests **in the EPP itself** (per-family counters; see below) | — |
| `prefix-cache-scorer` | rewards endpoints whose LMCache likely holds the prefix | 3 |
| `active-request-scorer` | penalizes endpoints by running requests (sourced from DP-rank metrics) | 3 |
| `token-load-scorer` | penalizes by token throughput | 1 |
| `max-score-picker` | picks the top-scoring endpoint | — |

   The EPP config-text is rendered verbatim from the LLMInferenceService's
   `scheduler.config.inline` — KServe owns the EPP Deployment lifecycle, the
   chart only supplies the scheduler text. Weights and plugin commentary
   (per-family DP8 metrics exposure, engine-label sampling failure) from
   `charts/glm53-bundled/values.yaml` (epp profile) and live deployment args.
6. The EPP answers with one specific rank pod:port (8000–8007 of a specific
   pod); Envoy forwards there.

**BackendTrafficPolicy `fleet-glm-5-3`**
(`cluster/ns-envoy-ai-gateway-system/backendtrafficpolicies_gateway_envoyproxy_io.yaml`)
shapes the fleet path:

| Feature | Config | Why |
|---|---|---|
| Session affinity | `consistentHash` on headers `x-claude-code-session-id` **or** `x-openwebui-chat-id`, `tableSize: 65537` | sticky per conversation → prefix cache hits; consistent-hash keeps stickiness across endpoint churn |
| Circuit breaker | maxConnections 100000, maxParallelRequests 100000, maxPendingRequests 100000, maxParallelRetries 1024 | effectively off for connections; the LLM backpressure point is the EPP/vLLM queue, not Envoy |
| Active health check | HTTP GET `/healthz/glm-5.3`, hostname `peers.llm.example.internal`, every 5 s, 2 healthy / 3 unhealthy, `panicThreshold: 0` | e2e probe through the peers hairpin → health HTTPRoute (§9); panic mode disabled |
| Retry | `numRetries: 0`, retryOn `connect-failure,reset,retriable-status-codes` (503), backoff 100 ms base / 1 s max | **retries disabled at the BTP layer** — flagged as a design decision to review: LLM streams must not be replayed blindly, so recovery relies on host-selection retries instead (see below) |
| Request timeout | 3600 s | long generations |

**EnvoyPatchPolicy `fleet-glm-5-3-retry`**
(`cluster/ns-envoy-ai-gateway-system/envoypatchpolicies_gateway_envoyproxy_io.yaml`):
sets `host_selection_retry_max_attempts: 20` on the route, removes Envoy's
`auto_host_rewrite`, and pins `host_rewrite_literal` to
`peers.llm.example.internal` — so a failed upstream selection retries a
*different* rank up to 20 times without ever re-sending a body to a broken
host. This is the retry mechanism that replaces per-request retries.

### 7.3 Anthropic data plane (claude-compatible, passthrough)

Two AIGatewayRoute rules feed a **schema-Anthropic** backend:

- `glm53` / rule `claude-alias`: `x-ai-eg-model` regex `^claude-.*$`
  (Claude Code sends `x-ai-eg-model: claude-…`).
- `glm53-anthropic-alias` / rule `anthropic-fleet-alias`:
  `x-ai-eg-model = glm-5.3` **AND** header `anthropic-version` non-empty
  (OpenAI SDKs don't send anthropic-version; Anthropic SDKs always do).

Both → **AIServiceBackend `glm53-anthropic`** (schema Anthropic,
`modelNameOverride: glm-5.3`) → **Backend `glm53-ranks`** with 8 FQDN endpoints
`glm53-b200-ranks-svc.llm-glm53.svc.cluster.local:8000…8007`. With 2 pods the
Service's 8 ports × 2 endpoints = 16 rank endpoints; plain round-robin LB, no
EPP, no session affinity, no circuit breaker.

Why this path exists (`charts/glm53-bundled/templates/anthropic-backend.yaml`):
vLLM serves the Anthropic Messages API natively at `/v1/messages` (including
thinking blocks and `/v1/messages/count_tokens`). Routing
`/anthropic/v1/messages` to an Anthropic-schema AIServiceBackend is a protocol
**passthrough** — the extproc does no translation, so reasoning/thinking blocks
and count_tokens reach the client intact. The previous setup translated
Anthropic→OpenAI→Anthropic, which (ai-gateway v1.1.0) dropped vLLM's
"reasoning" field and 500-ed on count_tokens.

Why it may bypass the EPP: llm-d-router v0.10.0 cannot parse Anthropic bodies,
so its prefix-cache/queue scorers were blind on this traffic anyway. The
chart-owned Service `glm53-b200-ranks-svc` (ports rank-0…rank-7) exists because
the kserve-owned workload Service only carries port 8000 (rank 0) — kube-proxy
has no ClusterIP:8001-8007 otherwise.

### 7.4 Listener-level policies

- **ClientTrafficPolicy `client-buffer-limit`** (`http` listener): request
  bufferLimit 50 Mi (default 32 KiB → 413s on big prompts), idleTimeout 3600 s
  (long streams), HTTP/2 initial-stream/window sizes 16 Mi / 24 Mi, and a
  strip list of 10 client-forgeable headers (`x-aigw-client-id`,
  `x-llm-d-inference-objective`, `x-gateway-destination-endpoint`,
  `x-llm-d-model-name-rewrite`, `x-site-pin`, …) — clients cannot spoof
  quota identity, EPP objectives, or routing hints
  (`cluster/ns-envoy-ai-gateway-system/clienttrafficpolicies_gateway_envoyproxy_io.yaml`,
  rationale in `charts/envoy-ai-gateway/values.yaml`).
- **ClientTrafficPolicy `peers`**: mTLS client-certificate validation against
  the fleet CA (ConfigMap `llm-peer-ca`), requestID `PreserveOrGenerate`,
  late-response header `x-llm-served-by: site-a` (which site actually served),
  50 Mi bufferLimit.
- **Fleet PKI** (cert-manager, `charts/llm-model/templates/peer.yaml` +
  live Certificates): ClusterIssuer `llm-peer-issuer` ← CA Secret
  `llm-fleet-ca` — **the same CA Secret is installed on every fleet site**, so
  every site's peers cert chains to the same root. Server cert `llm-peer-server`
  (DNS = `peers.llm.example.internal`), client cert `llm-peer-client` (CN = site
  name, SPIFFE URI `spiffe://peers.llm.example.internal/site/site-a`), duration 2160 h,
  renewBefore 720 h. Chart warning: an expired peers cert silently drops this
  site out of every fleet model (requests just fail at other sites' mTLS).

---

## 8. Quota and multi-tenancy

### 8.1 Authentication

**SecurityPolicy `aigw-ui-api-key-auth`** targets the whole `http` listener
(every route on the public edge):

- `apiKeyAuth.credentialRefs` → Secret **`aigw-ui-api-keys`** (ns
  `envoy-ai-gateway-system`): an Opaque secret **managed by `aigw-ui`**
  (label `app.kubernetes.io/managed-by: aigw-ui`) holding one entry per
  client API key. **Structure only — key values are never exported**; rotate
  through aigw-ui, not kubectl.
- `extractFrom`: `Authorization` (Bearer) and `x-api-key` headers.
- `forwardClientIDHeader: x-aigw-client-id` — after auth, Envoy injects the
  authenticated client identity into that header **after** the
  client-buffer-limit strip list has removed any client-supplied copy.
- `sanitize: true`.

(`cluster/ns-envoy-ai-gateway-system/securitypolicies_gateway_envoyproxy_io.yaml`;
live Secret metadata in `cluster/ns-envoy-ai-gateway-system/secrets.yaml`.)

### 8.2 QuotaPolicy

Two variants on the same model quota, targeting the fleet AIServiceBackend
(`cluster/ns-envoy-ai-gateway-system/quotapolicies_aigateway_envoyproxy_io.yaml`):

| Policy | Target | Mode |
|---|---|---|
| `glm-5.3` | AIServiceBackend `fleet-glm-5-3` | **enforcement** |
| `fleetbe-glm-5-3` | AIServiceBackend `fleetbe-glm-5-3` (a shadow variant whose router sets header `x-llm-d-inference-objective: best-effort`, see below) | **shadow** (all buckets `shadowMode: true` — measures, never blocks) |

Per-model quota `glm-5.3`, shared counters in fleet Redis
(`quota-redis.apps.<hub-cluster>` over TLS; client Secret
`envoy-ai-quota-redis-client` with `password` + `ca.crt` keys — values not
exported). Bucket layout:

- **7 per-client buckets**: regex `^<client-N>\.[a-f0-9]+$` on
  `x-aigw-client-id` (client names redacted here as client-1…client-7), each
  duration `1d`, limit `1,000,000` cost units/day.
- **defaultBucket**: enforcement 116,000,000 / `1h`; shadow 4,294,967,295 / `1h`
  (effectively unlimited while shadow calibrates).
- **serviceQuota**: 4,294,967,295 / `1s` — fleet-wide global ceiling.

### 8.3 Cost model (token weighting)

`llmRequestCosts` on the routes define the raw token counters
(`llm_input_token`, `llm_output_token`, `llm_reasoning_token`,
`llm_total_token` — sourced from extproc usage extraction, which requires the
vLLM billing flags of §4.2). The quota `costExpression` converts a request's
token mix into cost units:

```text
((cached_input_tokens <= input_tokens ? input_tokens - cached_input_tokens : input_tokens) * 11600u
 + (cached_input_tokens <= input_tokens ? cached_input_tokens : 0u) * 1160u
 + output_tokens * 46300u) / 1000000u
```

I.e. per-token weights: **cached input 1160 : uncached input 11600 : output
46300** — cached input is 10× cheaper than uncached input; output tokens cost
4× an uncached input token. The ternaries guard against backends reporting
`cached > input`. Rationale: output dominates GPU seconds (decode), prefix
cache hits are nearly free (no prefill), so the formula prices compute, not
tokens.

### 8.4 Best-effort / InferenceObjective

An **InferenceObjective `best-effort`** (`llm-d.ai/v1alpha2`, priority −1,
poolRef `glm53-b200-inference-pool`) lets shadow-policy traffic select the same
pool with a different scheduling objective — the aigw-ui "best-effort" flavor
distinguished by the `x-llm-d-inference-objective` header
(`cluster/ns-llm-glm53/inferenceobjectives_llm_d_ai.yaml`).

## 9. Health checking and recovery

| Mechanism | Config | Notes |
|---|---|---|
| Peers health route | HTTPRoute `glm53-peer-health` on the `peers` listener: path `/healthz/glm-5.3` → URLRewrite to `/health` → Service `glm53-b200-kserve-workload-svc:8000` | probes **vLLM rank 0 directly**, bypassing EPP/InferencePool — the active health checks of §7.2 hit this through the hairpin, giving an e2e gateway→vLLM signal |
| Envoy active HC | 5 s interval, 2 consecutive healthy, 3 unhealthy marks an endpoint down | combined with `panicThreshold: 0` (panic mode disabled: even if all endpoints are down Envoy keeps honoring unhealthiness rather than panic-routing) |
| Kube probes | startup/readiness/liveness on `:8208` (§4.4) | supervisor-level; readiness gates EndpointSlice membership |
| Circuit breaker | BTP `fleet-glm-5-3` (§7.2) | high limits — the real backpressure is vLLM's scheduler queue |
| Retry | BTP `numRetries: 0` + EnvoyPatchPolicy host-selection retries ×20 | **Design decision to review**: no per-request retries anywhere on the fleet path (streaming responses can't be safely replayed), so a mid-stream backend failure surfaces to the client; recovery = new request, which host-selection retry steers to a healthy rank |
| EPP failureMode | `FailOpen` | EPP down → Envoy plain-LBs across 8000-8007 instead of failing requests (correct for availability; loses cache-aware placement) |
| Quota failure mode | `--quotaRateLimitFailureModeDeny=false` | Redis/ratelimit down → requests pass unbilled |
| LMCache engine | TCP :5555 probes (§5) | failure isolates caching, not serving |
| Rolling protection | PDB on envoy dataplane (minAvailable 1 of 3); inference pod strategy §10 | |

Operational warnings from the charts (`charts/glm53-bundled/README.md`): cold
boot is ~15–20 min per inference pod (weight load + compile; VLLM_ENGINE_READY_TIMEOUT_S
3600 covers it); `InferencePoolReady=False` on the InferencePool is a known
cosmetic issue (Envoy Gateway v1.9 never writes pool status conditions).

## 10. Rolling deployment and blast radius

| Deployment | Strategy | Blast radius |
|---|---|---|
| `glm53-b200-kserve` (2 pods, 1/node) | RollingUpdate `maxUnavailable: 1`, `maxSurge: 0` | **No free GPUs for a surge pod** — maxSurge 0 avoids deadlock (a surged third pod could never schedule with 16/16 GPUs requested). One node's pod at a time goes down: during a rollout the fleet runs at 50% rank capacity, and every request served by the draining pod's prefix cache falls back to LMCache T1/T2 on the surviving node or re-prefills. With terminationGracePeriod 300 s + shutdown-timeout 280 s, in-flight streams drain up to 5 min before the rank exits. |
| `glm53-node-prep`, LMCache DaemonSets | maxSurge 0 / maxUnavailable 1 | one node at a time loses its cache server; vLLM falls back to local KV only |
| EPP `glm53-b200-kserve-router-scheduler` | **Recreate**, 1 replica | a few seconds of FailOpen plain-LB during restart (by design — cache-aware routing degrades, serving doesn't stop) |
| Envoy dataplane | 3 replicas + PDB minAvailable 1 | rolling, no downtime |

Argo CD ordering per chart sync-waves (CRDs −10 → SCC −5 → controller 0 →
GatewayClass 1 → Gateway 2 → routes 3, `charts/envoy-ai-gateway/values.yaml`)
stages the gateway stack before routes attach. The glm53 Argo Application pins
the `bundled` branch (superset of the staged `main` chart in this archive) and
uses `ignoreDifferences` for the aigw-ui rewrites of route priority/weights.

## Appendix A. Sister workloads on the same gateway (context)

Documented because they share the Gateway, the L4 utility node, and the
patterns; all from `cluster/ns-llm-qwen38/`, `cluster/ns-llm-judge/`,
`charts/qwen38-bundled/`, `charts/qwen36-judge/`:

- **qwen38-l4** (ns `llm-qwen38`): Qwen3.8-27B-FP8, 1 pod TP=4 DP=1 on
  4× L4 of `util-node-1`, image `lmcache/vllm-openai:v0.5.5`,
  `--max-model-len=65536`, `--kv-cache-dtype=fp8_e4m3`, MTP 2 draft tokens,
  qwen3 parsers, requests 48c/64Gi → limits 96c/128Gi; its own LMCacheEngine
  (L1 200Gi RAM, L2 900Gi, chunkSize 1568 — a multiple of 784, the Qwen block
  quirk).
- **qwen36-judge** (ns `llm-judge`): Qwen3.6-35B-A3B-FP8 "judge" for the
  Claude Code PreToolUse hook (verdicts allow/ask/deny; deliberately a
  different model family so the judge never grades itself). 1 pod TP=2 on 2×
  L4, plain `vllm-openai:v0.30.0`, **no LMCache** (nothing shares its KV;
  vLLM prefix cache covers the repeated policy prompt), model fetched per
  pod-start by the KServe storage-initializer
  (`storage-initializer:v0.21.0-rc1`) from `s3://llms/Qwen/Qwen3.6-35B-A3B-FP8`
  (34.9 GB; the L4 node has no LVMS — single NVMe — so no PVC pre-warm).
  `--max-model-len=16384`, `--max-num-seqs=128`. Route:
  `x-ai-eg-model: judge` → direct AIServiceBackend (schema OpenAI) →
  InferencePool on its workload service; publishers name
  `publishers/llm-judge/models/judge`.

## Appendix B. Known-fragile spots (from chart commentary)

- EPP image patching vs Argo: patching the EPP Deployment image directly gets
  reverted by Argo syncs (kserve preset re-renders); the sanctioned path is
  the isvc `scheduler.config.inline`/preset images
  (`charts/glm53-bundled/README.md`).
- LMCache chunk-size modulus (64 for GLM-5.3, 784-multiples for qwen38) — a
  silent no-cache failure if violated.
- Ostree dual-mount (§6.2): a node where only one of the two `/var`
  resolutions lands on the LV looks healthy while writing weights to the boot
  disk.
- Peers cert expiry (§7.4): silent site ejection from the fleet.
- The `glm53-bundled` chart in this archive (`main` branch) lags the live
  `bundled` branch (e.g. staged values show `kv fp8_e4m3`, util 0.90, seqs 64,
  MTP 5, glm47 reasoning parser, OffloadingConnector; live runs fp8, 0.85,
  512, MTP 3, glm45, LMCacheMPConnector). Live YAML is authoritative.
