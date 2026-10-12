# popai

GitOps **values** repository for the popai day-2 GPU/AI operator stack, following the
new day-2 GitOps architecture (same topology as `sigs/ocp.git` and `sigs/flashback.git`).
ArgoCD wiring is provided by
[argocd-day2-platform](https://git.example.internal/internal/gitops-day2-prod/argocd-day2-platform.git):
the `groups` ApplicationSet auto-discovers this repo and renders the
`mces` → `clusters` → `operators` ApplicationSet chain, generating one ArgoCD Application
per operator per hosted cluster. Each operator's helm chart lives in a **separate** chart
repo under `popai/helm-charts/<name>-chart.git` (referenced from `operators/<name>/<name>.yaml`).

## Layout

```
operators/<name>/<name>.yaml      # app config (repourl, targetRevision, projectNamespace, syncPolicy, ...)
operators/<name>/values.yaml      # chart defaults
operators/<name>/ocp-versions/<ver>/…   # optional per-OCP-version overrides
defaults/hub/README.md            # placeholder — nothing deployed on the ArgoCD hub
defaults/mces/README.md           # placeholder — nothing deployed on MCE hubs (in-cluster)
defaults/hosted-clusters/README.md # placeholder — no cluster-wide defaults yet
sites/<site>/<env>/mces/<mce>/<cluster>/<name>/values.yaml   # per-cluster helm overrides
```

## Apps (15)

| App | Chart repo | Namespace | Catalog |
|---|---|---|---|
| catalog-sources | `popai/helm-charts/catalog-sources-chart.git` | openshift-marketplace | (defines CatalogSources) |
| gpu | `popai/helm-charts/gpu-chart.git` | nvidia-gpu-operator | cs-nvidia-26.3-4.22 |
| network | `popai/helm-charts/network-chart.git` | nvidia-network-operator | cs-nvidia-26.3-4.22 |
| lvms | `popai/helm-charts/lvms-chart.git` | openshift-storage | cs-operator-index-4-22 |
| nfd | `popai/helm-charts/nfd-chart.git` | openshift-nfd | cs-operator-index-4-22 |
| nmstate-rdma | `popai/helm-charts/nmstate-rdma-chart.git` | openshift-nmstate | cs-operator-index-4-22 |
| numaresources | `popai/helm-charts/numaresources-chart.git` | openshift-numaresources | cs-operator-index-4-22 |
| istio | `popai/helm-charts/istio-chart.git` | openshift-operators | cs-operator-index-4-22 |
| lws | `popai/helm-charts/lws-chart.git` | openshift-lws-operator | cs-operator-index-4-22 |
| monitoring | `popai/helm-charts/monitoring-chart.git` | rdma-monitoring | (no OLM) |
| kserve | `popai/helm-charts/kserve-chart.git` | kserve | (no OLM; CRDs + controller + cert-manager webhooks) |
| envoy-gateway | `popai/helm-charts/envoy-gateway-chart.git` | envoy-gateway-system | (no OLM) |
| envoy-ai | `popai/helm-charts/envoy-ai-chart.git` | envoy-ai-gateway-system | (no OLM) |
| glm53 | `popai/helm-charts/glm53-chart.git` | llm-glm53 | (no OLM; the GLM-5.3 model bundle) |
| lmcache | `popai/helm-charts/lmcache-chart.git` | lmcache-operator-system | (no OLM; CRDs >256KiB → ServerSideApply) |

## Clusters

| Cluster | MCE | Site / Env | OCP |
|---|---|---|---|
| cluster-gpu-test | cluster-mce-prod | site-a / prod | 4.22.8 |
| cluster-llm-prep | cluster-mce-prep | site-a / prep | 4.22.8 |

Operator selection is **directory-driven**: an operator deploys to a hosted cluster iff a
directory exists at `sites/<site>/<env>/mces/<mce>/<cluster>/<operator>/`. Adding a new
cluster = creating its directory tree under the right MCE; adding an operator to an
existing cluster = adding its directory with a `values.yaml`.

## How it wires up

1. `catalog-sources` deploys first (sync-wave 0) — defines the 3 CatalogSources every other
   chart references by name (`cs-operator-index-4-22`, `cs-nvidia-26.3-4.22`, `generic-cs`).
2. Each OLM chart carries its own Namespace + OperatorGroup + Subscription + CR(s), 4.22-aligned.
3. Value files layer (last wins), as rendered by the `deploy` chart in argocd-day2-platform:

```
operators/<op>/values.yaml
operators/<op>/ocp-versions/<ver>/values.yaml
sites/<site>/values.yaml
sites/<site>/<env>/values.yaml
defaults/hosted-clusters/<op>/values.yaml
defaults/hosted-clusters/<op>/values-<env>.yaml
defaults/hosted-clusters/<op>/values-<cluster>.yaml
sites/<site>/<env>/mces/<mce>/values.yaml
sites/<site>/<env>/mces/<mce>/<cluster>/values.yaml
sites/<site>/<env>/mces/<mce>/<cluster>/<op>/values.yaml
```

App config (`<op>.yaml`) layers the same way. The OCP version used for the
`ocp-versions/<ver>/` layer comes from the day1 `platform-config` repo
(`mastertag: 4.22.8-x86_64` for `cluster-gpu-test`).

popai deploys **only on hosted clusters** — nothing on the MCE hubs (`defaults/mces/`)
or on the ArgoCD hub (`defaults/hub/`).

## Notes

- `cluster-gpu-test` is a mixed GPU cluster: standalone (non-RoCE) B300 GPU nodes plus
  H200 RoCE nodes. The GPU driver split is done via the NVIDIADriver CRD with the
  `nvidia.com/driver-config` label (`roce` / `standard`) — see the comments in
  `sites/site-a/prod/mces/cluster-mce-prod/cluster-gpu-test/gpu/values.yaml` for the
  full rationale (digest pinning, certConfig must stay empty on this cluster, etc.).
- The `monitoring` chart's `nmstate`/RoCE-related values are inert until RoCE is activated;
  see the comments in each per-cluster `values.yaml`.
- `operators/<op>/<op>.yaml` files keep `preserveResourcesOnDeletion: true` for consistency
  with `sigs/ocp.git`. Note: the `deploy` chart in argocd-day2-platform does not currently
  render this key — it is inert in both repos.
- `gpu` sets `ignoreDifferences` on the `ClusterPolicy` for operator-owned fields
  (`migManager.config`, `vgpuDeviceManager.config`, `kataManager`) that the gpu-operator
  injects after reconcile — without it ArgoCD reads them as perpetual drift.
- `lmcache` deploys only the operator/CRDs/webhook. The per-node cache
  servers (LMCacheEngine CRs) are rendered by the model chart that needs them
  (`glm53-chart`'s `lmcache:` block) in the model's namespace, because the
  engine image must match the vLLM image the model runs.
