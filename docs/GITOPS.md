# GITOPS.md — ArgoCD / GitOps structure of the LLM serving platform

Audience: a reviewing agent that has **only the sanitized stack archive** (this `docs/` directory's parent).
Sources used for this doc (all paths cited below are relative to the archive root):

- `gitops/app-of-apps/` — checkout **A** of the ArgoCD *values repo* (newer snapshot; 17 apps registered)
- `gitops/platform-repo/` — checkout **B** of the same repo (older snapshot; see §3.4)
- `charts/` — Helm chart sources the apps render
- `live-cluster/` — live-state export of `cluster-llm-prep` (7 LLM-related namespaces)

## 0. Naming conventions used in this doc

Real identifiers are sanitized with the same mapping the archive sanitizer applies, so doc and
YAMLs share one vocabulary. Everything else (chart names/versions, image tags, digests, values
keys, namespaces, S3 bucket paths, OLM CSV names) is verbatim from the sources.

| Sanitized name | Meaning |
|---|---|
| `site-a` | the site directory in `sites/` (the only site present in this export) |
| `cluster-llm-prep` | LLM **prep** hosted cluster — the one live-exported in `live-cluster/` |
| `cluster-llm-prod` | LLM **prod** hosted cluster (site overlay only, not live-exported) |
| `cluster-gpu-test` | GPU **test/prod** hosted cluster (site overlay only) |
| `cluster-mce-prep`, `cluster-mce-prod` | the two MCE (hosted-cluster management) directories under `mces/` |
| `cluster-hub-prod` | the ArgoCD hub cluster the ApplicationSet chain runs on |
| `gpu-node-1`, `gpu-node-2` | the two B200 GPU worker nodes |
| `util-node-1` | the L4 / utility GPU node |
| `git.example.internal` | the Git server (all `<name>-chart.git` repos live under `popai/`) |
| `s3.example.internal` | the S3 model-store endpoint (`s3://llms/...` bucket paths kept as-is) |
| `registry-internal/` | container registry (both internal registry path prefixes collapse here; tags/digests kept) |
| `popai` | values-repo / ArgoCD project codename (kept — appears throughout the repo itself) |

All IP literals (including the gateway VIP) are rewritten by the sanitizer to RFC5737
TEST-NET addresses (`192.0.2.x`); prose below says "the gateway VIP" instead of quoting one.
`*.svc.cluster.local` DNS names are Kubernetes-internal and kept as-is.

## 1. The app-of-apps pattern

### 1.1 The repos

Three kinds of git state cooperate; **only two are in the archive**:

| Repo | In archive? | Role |
|---|---|---|
| values repo (`gitops/app-of-apps/`, `gitops/platform-repo/`) | yes (2 checkouts) | *what* runs *where*: operator registration dirs, per-operator deploy config + values layers |
| per-operator chart repos `git.example.internal/popai/helm-charts/<name>-chart.git` | sources of 15 of them in `charts/` (missing: `kserve-chart`, `lmcache-chart`) | the Helm charts the apps render |
| `argocd-day2-platform` (`deploy` chart + ApplicationSet chain) | **no** | renders the actual ArgoCD Applications from the values repo |

App configs reference their chart repo by URL and branch, e.g. `gitops/app-of-apps/operators/glm53/glm53.yaml`
(`repourl: git.example.internal/popai/helm-charts/glm53-chart.git`, `targetRevision: bundled`);
`repourl` is all-lowercase by convention (a render quirk of the day2 tooling, documented in team brain).

### 1.2 The ApplicationSet chain

The day2 platform (not exported) drives a generator chain; the values repo is its data source.
Reconstructed from `gitops/app-of-apps/README.md` and the live tracking annotations:

```
argocd-day2-platform repo (NOT in archive)
│
└─▶ "groups" ApplicationSet ──── git directory generator ────▶ values repo
        └─▶ "mces" ApplicationSet            (renders per MCE dir)
                └─▶ "clusters" ApplicationSet  (renders per hosted-cluster dir, on that MCE's Argo)
                        └─▶ "operators" ApplicationSet (one entry per operators/<op>/ registration)
                                └─▶ "deploy" chart ── renders ONE ArgoCD Application per
                                     (operator × hosted cluster):  popai-<cluster>-<op>-deploy
                                     project: gitops-popai
                                        └─▶ Helm install of <op>-chart.git into projectNamespace
```

- **A directory is the registration.** `operators/<op>/` existing registers `<op>` for every
  hosted cluster unless excluded; `mces/<mce>/<cluster>/<op>/values.yaml` existing overrides
  values for that cluster (no marker files; discovery is `directories:` generators only,
  `*` never crossing `/` — README + team brain `day2-sites-tree-discovery-and-version-layers`).
- No Application/ApplicationSet YAML is stored in the values repo itself — the exported
  `operators/<op>/<op>.yaml` files are **inputs** (deploy config) to the `deploy` chart.

### 1.3 Application naming convention

Rendered leaf apps follow `<repo>-<cluster>-<operator>-deploy` in project `gitops-popai`
(project namespace template `gitops-{{repository}}` → `gitops-popai`; README + live annotations).
Every GitOps-managed object carries `argocd.argoproj.io/tracking-id` in the form
`<project>_<app>:<group>/<kind>:<ns>/<name>`. Observed live on `cluster-llm-prep`
(`live-cluster/ns-llm-glm53/aigatewayroutes_aigateway_envoyproxy_io.yaml` etc.):

```
gitops-popai_popai-cluster-llm-prep-glm53-deploy:aigateway.envoyproxy.io/AIGatewayRoute:llm-glm53/glm53
gitops-popai_popai-cluster-llm-prep-qwen36-judge-deploy:aigateway.envoyproxy.io/AIGatewayRoute:llm-judge/qwen36-judge
gitops-popai_popai-cluster-llm-prep-qwen38-deploy:aigateway.envoyproxy.io/AIGatewayRoute:llm-qwen38/qwen38
gitops-popai_popai-cluster-llm-prep-envoy-ai-deploy:gateway.networking.k8s.io/Gateway:envoy-ai-gateway-system/envoy-ai-gateway
gitops-popai_popai-cluster-llm-prep-envoy-gateway-deploy:…
gitops-popai_popai-cluster-llm-prep-kserve-deploy:…
gitops-popai_popai-cluster-llm-prep-lmcache-deploy:…
```

Helm labels on rendered objects: `app.kubernetes.io/instance: <op>`, `helm.sh/chart: <chart>-<version>`
(e.g. `glm53-bundled-0.1.0`, `envoy-ai-gateway-openshift-0.1.0`).

### 1.4 Value layering (defaults → sites overlay → operators)

Ten layers, **most specific wins** (`gitops/app-of-apps/README.md`, value-file resolution order):

| # | Layer | Path pattern (values repo) |
|---|---|---|
| 1 | chart defaults | inside the chart repo |
| 2 | operator team default | `operators/<op>/values.yaml` |
| 3 | operator default deploy config | `operators/<op>/<op>.yaml` |
| 4 | OCP-version operator values | `operators/<op>/ocp-versions/<v>/values.yaml` |
| 5 | OCP-version deploy config | `operators/<op>/ocp-versions/<v>/<op>.yaml` |
| 6 | site/env/MCE/cluster values | `sites/<site>/<env>/mces/<mce>/<cluster>/<op>/values.yaml` |
| 7 | site/env/MCE/cluster deploy config | `sites/.../<cluster>/<op>/<op>.yaml` |
| 8 | MCE-wide defaults | `defaults/mces/<mce>/<op>/values.yaml` |
| 9 | hosted-cluster-wide defaults | `defaults/hosted-clusters/<op>/values.yaml` |
| 10 | cluster folder itself | presence of the `<op>` dir under the cluster (values may be empty) |

Deploy config (`<op>.yaml`: `repourl`, `targetRevision`, `projectNamespace`, `syncPolicy`)
and values are **separate stacks**, layered the same way. Every slot uses
`ignoreMissingValueFiles=true` so layers can be sparse. The OCP-version layer is keyed by the
day1 `platform-config` `mastertag: 4.22.8-x86_64` (→ `ocp-versions/4.22.8/`; README).

### 1.5 How a hosted cluster inherits and overrides

Example — `cluster-llm-prep` (`gitops/app-of-apps/sites/site-a/prep/mces/cluster-mce-prep/cluster-llm-prep/`):

- **Inherits** every `operators/<op>/` registration by default (14 operator dirs exist under
  the cluster: catalog-sources, envoy-ai, envoy-gateway, glm53, gpu, kserve, lmcache, lws,
  monitoring, network, nfd, numaresources, qwen36-judge, qwen38).
- **Per-cluster overrides** via layer-6/7 dirs, e.g.:
  - `gpu/values.yaml` — splits `NVIDIADriver` CRs into a `roce` driver (GPU driver 570.148.02)
    for the B300/H200 pool nodes and a `standard` driver for plain workers, with distinct
    `driverUpgradePolicy`, plus clock-lock config for the B300 pool.
  - `envoy-ai/values.yaml` — `gateway.envoyProxy.replicas: 3`, `externalTrafficPolicy: Local`,
    dataplane SCC enablement, and the quota-Redis client secret (TLS Route on `cluster-hub-prod`).
  - `lws/lws.yaml` — deploy-config override switching `targetRevision: main` →
    `targetRevision: opensource-chart` (the only branch pin at cluster layer).
- `cluster-llm-prod` carries **no model charts**: 8 operator dirs (catalog-sources, gpu,
  istio, lws, monitoring, network, nfd, numaresources).
- `cluster-gpu-test` carries 11: those 8 plus kserve, lvms, nmstate-rdma (the RoCE NNCPs are
  only instantiated here — `mode: roce` + the per-node NIC/IP fabric plan; elsewhere `mode: ""`
  renders only the operator, `gitops/app-of-apps/operators/nmstate-rdma/values.yaml`).

## 2. Deployment flow

```
git push (values repo)                git push (chart repo, e.g. glm53-chart.git)
        │                                         │
        ▼                                         │
ApplicationSet chain re-renders on cluster-hub-prod
        │                                         │
        ▼                                         ▼
leaf Application popai-<cluster>-<op>-deploy ── fetch chart repo @ targetRevision
        │                                       (main; glm53 pins branch "bundled";
        ▼                                        lws on cluster-llm-prep pins "opensource-chart")
helm template with the 10-layer merged values
        │
        ▼
apply into projectNamespace (ServerSideApply where configured;
ignoreDifferences protects controller-mutated fields)
```

Sync is otherwise **manual** (§5): a push updates the desired state in git; the leaf app applies
it when synced (day2 convention: leaf apps are manual-sync — team brain
`day2-sites-tree-discovery-and-version-layers`).

### 2.1 Charts → namespaces

| Chart | Rendered by app | Target namespace(s) |
|---|---|---|
| `glm53-bundled-0.1.0` | `popai-cluster-llm-prep-glm53-deploy` | `llm-glm53` (chart also creates it) |
| `qwen36-judge-0.2.2` | `popai-cluster-llm-prep-qwen36-judge-deploy` | `llm-judge` |
| `qwen38-bundled-0.2.6` | `popai-cluster-llm-prep-qwen38-deploy` | `llm-qwen38` |
| `envoy-ai-gateway-openshift-0.1.0` | `popai-cluster-llm-prep-envoy-ai-deploy` | `envoy-ai-gateway-system` (incl. ratelimit pods) |
| `envoy-gateway-openshift-0.1.0` | `popai-cluster-llm-prep-envoy-gateway-deploy` | `envoy-gateway-system` |
| kserve chart (source **not in archive**) | `popai-cluster-llm-prep-kserve-deploy` | `kserve` (+ webhook pods) |
| lmcache chart (source **not in archive**) | `popai-cluster-llm-prep-lmcache-deploy` | `lmcache-operator-system` |
| `platform/catalog-sources` | per-cluster catalog-sources app | `openshift-marketplace` |
| `platform/gpu` | per-cluster gpu app | `nvidia-gpu-operator` |
| `platform/network` | per-cluster network app | `nvidia-network-operator` |
| `platform/lvms` | per-cluster lvms app | `openshift-storage` |
| `platform/nfd` | per-cluster nfd app | `openshift-nfd` |
| `platform/nmstate-rdma` | per-cluster nmstate-rdma app | `openshift-nmstate` |
| `platform/numaresources` | per-cluster numaresources app | `openshift-numaresources` |
| `platform/istio` | per-cluster istio app | `openshift-operators` (operator) + `istio-system` / `istio-cni` (CRs) |
| `platform/lws` | per-cluster lws app | `openshift-lws-operator` |
| `platform/monitoring` | per-cluster monitoring app | `rdma-monitoring`, `openshift-monitoring` (grafana), `prometheus-mcp` |

### 2.2 Sync waves (ordering inside an app)

- CatalogSources: sync-wave 1 (must resolve before any Subscription; the chart values comment
  claims wave 0 — the rendered annotation is `argocd.argoproj.io/sync-wave: "1"`,
  `charts/platform/catalog-sources/templates/catalogsources.yaml`).
- envoy-gateway: CRDs at wave -10 (PreSync-hooked `install-crds` Job), control plane at 0.
- envoy-ai: CRDs -10 → SCC binding -5 → controller 0 → `EnvoyGateway` 1 → `Gateway` 2 →
  routes 3 → ratelimit 5 (`charts/envoy-ai-gateway/values.yaml` header).
- gpu: operator subscription wave 3, clock-lock DaemonSet wave 5 (after driver install).
- nmstate: `NMState` CR wave 4, NNCPs wave 5.
- qwen38: `LMCacheEngine` at wave -1 (before the LLMInferenceService).

### 2.3 Cross-app prerequisites (not enforced by Argo)

- `envoy-gateway` must exist before `envoy-ai` (gateway.envoyproxy.io + InferencePool CRDs
  are owned by envoy-gateway's CRD job — envoy-ai's `Backend`s use them).
- `lmcache` operator must exist before `qwen38`'s `LMCacheEngine` CR.
- kserve's LLM preset is patched to a custom EPP image **out-of-band**
  (`charts/glm53-bundled/scripts/patch-llm-preset.sh`; the `LLMInferenceServiceConfig`
  is Argo-managed on the live cluster, so the patch may be reverted by a later kserve-app
  sync — documented in `charts/glm53-bundled/README.md`).
- S3 model-store secrets (`s3-credentials` in each llm-* namespace) are pre-created out-of-band;
  `glm53-bundled` has `s3Secret.create: false` by default.
- `cert-manager` must be installed before envoy-ai (webhook certificates — chart README).

## 3. The values repo layout

```
popai/  (values repo — the exported root of gitops/app-of-apps/ and gitops/platform-repo/)
├── README.md                       # wiring contract (layering, registration, app matrix)
├── defaults/                        # layer-8/9 placeholder trees (nothing deployed on hubs)
│   ├── hosted-clusters/README.md
│   ├── hub/README.md
│   └── mces/README.md
├── operators/                       # team defaults + registrations (one dir per operator)
│   └── <op>/{<op>.yaml, values.yaml, [examples/, scripts/, files/]}
└── sites/site-a/
    ├── prep/mces/cluster-mce-prep/cluster-llm-prep/<op>/{values.yaml|<op>.yaml}   # 14 op dirs
    └── prod/
        ├── mces/cluster-mce-prep/cluster-gpu-test/<op>/values.yaml               # 11 op dirs
        └── mces/cluster-mce-prod/cluster-llm-prod/<op>/values.yaml                # 8 op dirs
```

`defaults/` dirs are placeholder trees (READMEs only) — they exist so per-scope overrides can
be added without restructuring; nothing is deployed to the ArgoCD hub or MCEs themselves.

### 3.1 Operator catalogue (`operators/` — every directory and its role)

| Dir | Chart repo (`git.example.internal/popai/helm-charts/…`) | Namespace | Installs | Role / notes |
|---|---|---|---|---|
| `catalog-sources` | `catalog-sources-chart.git` | `openshift-marketplace` | CatalogSources | OLM catalogs every other chart resolves packages from (see §3.2 for the name drift) |
| `gpu` | `gpu-chart.git` | `nvidia-gpu-operator` | Namespace, OperatorGroup, Subscription (`gpu-operator-certified.v26.3.3`), ClusterPolicy, NVIDIADriver CRs, clock-lock | GPU driver + toolkit + DCGM; cluster layer splits `roce` (driver 570.148.02, B300/H200 pool) vs `standard` drivers; clock-lock DaemonSet runs `chronos.sh` to pin GPU clocks (wave 5) |
| `network` | `network-chart.git` | `nvidia-network-operator` | Subscriptions `nvidia-network-operator.v26.4.1` + `nvidia-maintenance-operator.v26.4.0`, NicClusterPolicy, NicNodePolicies, NicConfigurationTemplate | NIC driver/OFED + RoCE config for GPU pools; NicClusterPolicy pins node pools (e.g. the B200/H200 worker pool) |
| `lvms` | `lvms-chart.git` | `openshift-storage` | Subscription `lvms-operator.v4.22.0`, LVMCluster | thin-provisioned LVs from `vg1` (grafana PVC, qwen38 L2 cache) |
| `nfd` | `nfd-chart.git` | `openshift-nfd` | Subscription `nfd.4.22.0-202608042055`, NodeFeatureDiscovery instance | labels GPU/RDMA features other charts select on |
| `nmstate-rdma` | `nmstate-rdma-chart.git` | `openshift-nmstate` | Subscription `kubernetes-nmstate-operator.4.22.0-202608050531`, NMState CR, RoCE/IB NodeNetworkConfigurationPolicies | host NIC IPs/routes for RDMA rails; `mode: ""` by default → renders only the operator; per-node NNCPs only on cluster-gpu-test (wave 5; metrics bindAddress :8089 avoids a kube-rbac-proxy port collision) |
| `numaresources` | `numaresources-chart.git` | `openshift-numaresources` | Subscription `numaresources-operator.v4.22.1`, NUMAResourcesOperator CR | NUMA-aware scheduling (RTE) for GPU workers |
| `istio` | `istio-chart.git` | `openshift-operators` / `istio-system` / `istio-cni` | Subscription `servicemeshoperator3.v3.4.1`, Istio + IstioCNI CRs (Sail) | service mesh 3.4.1 / Istio 1.30.3 (not on cluster-llm-prep) |
| `lws` | `lws-chart.git` | `openshift-lws-operator` | Subscription `leader-worker-set.v1.0.0`, LeaderWorkerSetOperator CR | LeaderWorkerSet API used by kserve LLM presets; on cluster-llm-prep the deploy config is overridden to `targetRevision: opensource-chart` |
| `monitoring` | `monitoring-chart.git` | `rdma-monitoring` + `openshift-monitoring` + `prometheus-mcp` | rdma-exporter, hpc-observability, prometheus-mcp, grafana (4 vendored subcharts, no OLM) | RDMA/GPU/fabric/node exporters (ports 9402/9500/9501), Grafana with HPC dashboards, MCP server for Prometheus queries; `global.clusterName` set per cluster |
| `kserve` | `kserve-chart.git` (source **not exported**) | `kserve` | KServe CRDs + controller + llm-d scheduler (EPP) | model-serving API (`LLMInferenceService`, InferencePool); preset `llm-scheduler` image patch (§2.3) |
| `envoy-gateway` | `envoy-chart.git` | `envoy-gateway-system` | Envoy Gateway control plane v1.9.x + CRDs | Gateway API implementation incl. InferencePool backend support |
| `envoy-ai` | `envoy-ai-chart.git` | `envoy-ai-gateway-system` | Envoy AI Gateway controller v1.2.0 + ratelimit + `Gateway`/`GatewayClass`/routes | the shared AI Gateway dataplane fronting all models; aigw-ui renders QuotaPolicies against its routes |
| `glm53` | `glm53-chart.git` @ `bundled` | `llm-glm53` | glm53-bundled chart (see CHARTS.md §4) | GLM-5.3 flagship: 2×B200 nodes, DP8×EP8, Anthropic-schema passthrough |
| `qwen38` | `qwen38-chart.git` | `llm-qwen38` | qwen38-bundled chart | Qwen3.8-27B-FP8: 1×L4 node, TP4, LMCacheEngine L1+L2 tiers |
| `qwen36-judge` | `qwen36-judge-chart.git` | `llm-judge` | qwen36-judge chart | judge model with an OpenAI-protocol route for quota accounting |
| `lmcache` | `lmcache-chart.git` (source **not exported**) | `lmcache-operator-system` | LMCache operator + CRDs | serves the `LMCacheEngine` CRs the model charts create; ServerSideApply because its CRDs are 220–335 KB |

`operators/<op>/` also carries supporting material where relevant: `operators/glm53/scripts/`
(dig, download-model, force-sync), `operators/qwen38/{examples,scripts,files}/`,
`operators/monitoring/files/dashboards/`, `operators/lws/examples/`.

### 3.2 Catalog sources — README/values drift (fact, not resolved)

- Chart defaults (`charts/platform/catalog-sources/values.yaml`) define three sources:
  `cs-operator-index-4.22`, `cs-nvidia-26.3-4.22`, `generic-cs` (Red Hat 4.20-full index).
- The values repo (`gitops/app-of-apps/operators/catalog-sources/values.yaml`) overrides with two
  **different** sources: `generic-cs-certified` (certified 4.22-full) and
  `generic-cs-community` (community 4.22-full).
- Subscriptions across operators reference `generic-cs-certified` (gpu, network) and
  `generic-cs` (istio, lvms, lws, nfd, numaresources, nmstate-rdma).
- The README's app matrix cites the chart-default names (cs-operator-index…/cs-nvidia…), i.e. the
  README predates the values change. When diffing live CatalogSources against the repo,
  use the values file, not the README, as desired state.

### 3.3 Registration matrix (which clusters run which operators)

| Operator | cluster-llm-prep | cluster-llm-prod | cluster-gpu-test |
|---|:-:|:-:|:-:|
| catalog-sources | ✔ | ✔ | ✔ |
| envoy-ai / envoy-gateway | ✔ | — | — |
| glm53 / qwen38 / qwen36-judge | ✔ | — | — |
| lmcache / kserve | ✔ | — | ✔ (kserve) |
| gpu / network / nfd / numaresources / lws / monitoring | ✔ | ✔ | ✔ |
| istio | — | ✔ | ✔ |
| lvms | — | — | ✔ |
| nmstate-rdma (NNCPs active) | — | — | ✔ |

### 3.4 The two checkouts (A = `gitops/app-of-apps/`, B = `gitops/platform-repo/`)

Same repo, different points in time. Differences (`diff -rq`):

| File | Difference |
|---|---|
| `README.md` | A lists 17 apps (incl. qwen36-judge, qwen38); B lists 15 |
| `operators/envoy-ai/values.yaml` | A populated (image mirror pins); B empty |
| `operators/envoy-gateway/values.yaml` | A populated (v1.9.2 control-plane + shutdown-manager pins); B empty |
| `operators/glm53/glm53.yaml`, `qwen36-judge/…`, `qwen38/…` | A adds ServerSideApply syncOptions, retry blocks, ignoreDifferences (see §5) |
| `sites/.../cluster-llm-prep/envoy-ai/values.yaml` | A adds rateLimit Redis client wiring (existingSecret + TLS URL) |

**A is the newer snapshot**; B is kept in the archive only as provenance (the pipeline's
`collect_sources.sh` exported both). Use A when citing current desired state.

## 4. GitOps-managed vs NOT (live-only objects)

### 4.1 GitOps-managed (rendered by the leaf apps)

Everything the 7 apps on `cluster-llm-prep` render (evidence: `argocd.argoproj.io/tracking-id`
annotations naming `gitops-popai_popai-cluster-llm-prep-<op>-deploy`): the GLM/qwen/judge
model namespaces' chart-owned objects (KServe `LLMInferenceService`, ranks Service, Backends,
AIServiceBackends, AIGatewayRoutes, node-prep DaemonSet, pull Jobs, PV/PVC, SCC/Role bindings),
the two envoy namespaces, kserve controller/CRs, lmcache operator.

### 4.2 Live-only objects created by **aigw-ui** (the hub-hosted gateway-admin web UI)

Identified in `live-cluster/` by `labels: app.kubernetes.io/managed-by: aigw-ui` and
`gateway.envoyproxy.io/aigw-ui-quota-revision: <hash>` annotations; **no** ArgoCD tracking-id:

| Object(s) | Namespace | Purpose |
|---|---|---|
| `AIGatewayRoute/fleet-glm-5-3` + child `HTTPRoute/fleet-glm-5-3` | `envoy-ai-gateway-system` | fleet entry route (a stable service name fronting glm-5.3) |
| `AIServiceBackend/fleet-glm-5-3`, `Backend/fleet-glm-5-3`, `BackendTrafficPolicy/fleet-glm-5-3`, `EnvoyPatchPolicy/fleet-glm-5-3-retry` | `envoy-ai-gateway-system` | fleet backend chain + retry patch policy |
| `QuotaPolicy/fleetbe-glm-5-3`, `QuotaPolicy/glm-5-3` | `envoy-ai-gateway-system` | per-tenant token quotas (attach to the AIServiceBackends) |
| `QuotaPolicy/judge`, `QuotaPolicy/qwen3-8-27b-fp8` | `llm-judge`, `llm-qwen38` | per-model quotas |
| `Secret/aigw-ui-api-keys`, `SecurityPolicy/aigw-ui-api-key-auth` | `envoy-ai-gateway-system` | API-key auth (Authorization header extraction) |
| `InferenceObjective/best-effort` | `llm-glm53` | aigw-ui scheduling objective |

These are **not reproducible from the archive**; the llm-model chart exposes only the hooks
(`aigw-ui.io/*` annotations on the LLMInferenceService, `route.direct` listener selection —
`charts/llm-model/README.md`), it does not create the fleet objects.

### 4.3 Controller-generated (neither chart nor aigw-ui)

- `HTTPRoute`s with `gateway.envoyproxy.io/ai-gateway-generated: "true"` — synthesized by the
  Envoy AI Gateway controller from each AIGatewayRoute.
- KServe-generated workload objects: per-model Deployment, workload Service, `InferencePool`,
  EPP Deployment, and the KServe router `HTTPRoute` (visible in `live-cluster/ns-llm-*`).
- Envoy Gateway-generated data-plane Deployment/Service in `envoy-ai-gateway-system`
  (from the `EnvoyGateway`/`Gateway` objects).

### 4.4 Drift considerations

1. **No prune/self-heal keys anywhere in the exported app configs** (§5) — deleted repo dirs
   orphan workloads (team brain: only the Application CR goes; `argocd app delete --cascade`
   is the manual teardown path).
2. **Live Gateway is ahead of the exported values**: the live `Gateway/envoy-ai-gateway`
   (`live-cluster/ns-envoy-ai-gateway-system/gateways_gateway_networking_k8s_io.yaml`) has a
   `peers` HTTPS listener (8443, mTLS, Secret `llm-peer-server`, allowedRoutes selector
   `aigw-ui.io/serving: "true"`) and a `spec.addresses` entry pinning the gateway VIP; the
   archived chart renders peers only with `gateway.peers.enabled=true` (default **false**) and
   never renders `spec.addresses`. The live app renders from values/chart state beyond this
   archive (the aigw-ui fleet feature described in `charts/llm-model/README.md`).
3. **Orphan-protected Secret**: `envoy-ai-quota-redis-client` carries
   `argocd.argoproj.io/sync-options: IgnoreExtraneous=true,Prune=false` (site values comment)
   so a later sync cannot delete it once the chart stops rendering it.
4. **EPP preset patch** (kserve `LLMInferenceServiceConfig` image override) is Argo-managed
   and **will revert** on the next kserve-app sync if not reapplied
   (`charts/glm53-bundled/README.md`).
5. **Catalog-source naming** mismatch (§3.2): README vs values vs subscription `source:` refs.
6. **Immutable pull Jobs**: glm53/qwen38 pull Jobs are `Job` specs (immutable template); value
   changes need `RespectIgnoreDifferences` + job deletion (qwen38 app sets it; see §5).

## 5. Sync policies observed

From the exported `operators/<op>/<op>.yaml` `syncPolicy:` blocks (checkout A). Exact flags
per app are in those files; the table transcribes them (`—` = block absent in that app config).

| App | syncOptions | retry | ignoreDifferences |
|---|---|---|---|
| glm53 | `CreateNamespace=true`, `ServerSideApply=true` | limit 10, backoff 30 s / factor 2 / max 5 m | ServiceAccount `imagepullsecrets` (dockercfg); AIGatewayRoute (controller rewrites status/targetRefs) |
| qwen36-judge | `CreateNamespace=true`, `ServerSideApply=true` | same retry | ServiceAccount `imagepullsecrets`; AIGatewayRoute |
| qwen38 | `CreateNamespace=true`, `ServerSideApply=true`, `RespectIgnoreDifferences=true` | same retry | ServiceAccount `imagepullsecrets`; AIGatewayRoute; Job `spec.template.labels` (pull-job mutation) |
| envoy-ai | `CreateNamespace=true`, `SkipDryRunOnMissingResource=true`, `ServerSideApply=true` | same retry | — |
| envoy-gateway | `CreateNamespace=true`, `SkipDryRunOnMissingResource=true`, `ServerSideApply=true` | same retry | — |
| kserve | `CreateNamespace=true`, `ServerSideApply=true` | same retry | — |
| lmcache | `CreateNamespace=true`, `ServerSideApply=true` | same retry | ServiceAccount `imagepullsecrets` |
| monitoring | `CreateNamespace=true`, `ServerSideApply=true` | — | ServiceAccount `imagepullsecrets` |
| gpu | `CreateNamespace=true`, `SkipDryRunOnMissingResource=true`, `ServerSideApply=true` | — | ClusterPolicy (driver status conditions) |
| catalog-sources, network, nfd, nmstate-rdma, numaresources, istio, lws, lvms | `CreateNamespace=true`, `SkipDryRunOnMissingResource=true` (+ `ServerSideApply=true` where present) | — | — |

Facts that matter to a reviewer:

- **No `automated:`, `prune:` or `selfHeal:` key appears in any exported app config**
  (verified by grep across both checkouts). Final Application specs are rendered by the
  `deploy` chart (not in the archive), so any policy it injects is not observable here —
  but team brain records day2 leaf apps as **manual-sync**.
- `preserveResourcesOnDeletion: true` is present in every `<op>.yaml` but is **inert** — the
  README documents it as a known no-op carried for a future deploy-chart feature.
- `ServerSideApply=true` matters where CRDs are huge (lmcache: 220–335 KB CRDs) and where
  controllers rewrite fields; `RespectIgnoreDifferences=true` (only qwen38) makes Argo honor
  fields mutated in-cluster on immutable Job templates.
- The retry block (limit 10, initial 30 s, factor 2, max 5 min) covers chart-fetch and
  CRD-dependency flakiness on first install.
