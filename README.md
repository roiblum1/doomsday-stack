# LLM Serving Stack — Sanitized Export

Sanitized, shareable export of an LLM serving stack deployed on an OpenShift 4.22
hosted cluster (`cluster-llm-prep`, site `site-a`): GLM-5.3 (B200 pair) + Qwen3.8 and a
Qwen3.6 judge model (L4 node), served via KServe `LLMInferenceService` / llm-d router
and fronted by an Envoy AI Gateway, with LMCache KV offload, per-user token quotas and
a cross-site "fleet" peering path. Export taken **2026-10-12**.

All real identifiers (hostnames, IPs, registry, cluster/site/node names, usernames) are
replaced — see `SECURITY_SANITIZATION.md` for methodology and the placeholder
conventions.

## Archive map

```
stack-export/
├── gitops/                     # Argo CD values repos (app-of-apps + platform-repo mirror)
│   ├── app-of-apps/            # the live GitOps source of the stack
│   │   ├── operators/<app>/    # app config (<app>.yaml: repo, revision, syncPolicy) + chart defaults values.yaml
│   │   ├── sites/site-a/.../cluster-llm-prep/<app>/values.yaml   # per-cluster overrides (last layer)
│   │   └── README.md           # day-2 architecture, 17-app table, value layering order
│   └── platform-repo/          # second copy of the same topology (hub-side platform repo)
├── charts/                     # the Helm charts the apps render
│   ├── glm53-bundled/          # GLM-5.3 bundle (llmisvc + node-prep + storage + gateway route)
│   ├── qwen38-bundled/         # Qwen3.8 bundle (+ LMCache engine template)
│   ├── qwen36-judge/           # judge model chart (storage-initializer based)
│   ├── llm-model/, generic-model/   # newer generic model charts (peer/objectives support)
│   ├── envoy-ai-gateway/       # AI Gateway wrapper chart (+ values-loadbalancer.yaml overlay)
│   ├── envoy-gateway/          # Envoy Gateway wrapper chart
│   ├── upstream-subcharts/     # vendored upstream: ai-gateway-helm-v1.2.0 (+ others)
│   └── platform/               # platform-level chart sources: gpu, istio, kserve, lmcache, lvms,
│                               #   monitoring, network, nfd, nmstate-rdma, numaresources, catalog-sources
├── live-cluster/               # sanitized live-state export (the "what is actually running" truth)
│   ├── ns-llm-glm53/ ns-llm-judge/ ns-llm-qwen38/          # model namespaces
│   ├── ns-envoy-ai-gateway-system/ ns-envoy-gateway-system/ # gateway control/data planes
│   ├── ns-kserve/ ns-lmcache-operator-system/              # controllers
│   └── cluster-scoped/         # GatewayClass, nodes, PVs, StorageClasses, RuntimeClasses, Tuned
└── docs/                       # this README, LIVE_STATE.md, SECURITY_SANITIZATION.md,
                                #   VERIFICATION.md (sanitize/verify pass logs)
```

## How to navigate

### (a) Understanding the architecture

1. `gitops/app-of-apps/README.md` — the deployment topology: 17 Argo CD apps, the
   value-file layering, which app owns which namespace.
2. `charts/glm53-bundled/README.md` (and the sibling chart READMEs) — what each chart
   deploys, ordering, out-of-band prerequisites, and design rationale (per-node static
   PVs, node-prep LVM, DP8 rank pool, EPP profile).
3. `docs/LIVE_STATE.md` — the full live inventory, per-object ownership (chart vs
   controller-generated vs live-only), serving/gateway/quota deep-dives, and the
   live-vs-chart deltas.

### (b) Reproducing the deployment

1. Platform first (per `gitops/app-of-apps/`): catalog-sources → OLM operators
   (gpu/network/lvms/nfd/…/kserve/lmcache) via the platform charts in `charts/platform/`.
2. Gateway: `charts/envoy-gateway` then `charts/envoy-ai-gateway`
   (+ `values-loadbalancer.yaml` and the site layer for LB/replicas/Redis).
3. Models: `charts/glm53-bundled`, `charts/qwen38-bundled`, `charts/qwen36-judge` —
   each chart's README documents prerequisites (S3 credential secrets out-of-band,
   KServe llm presets with the air-gapped EPP image patch, shared Gateway).
4. Live-only objects (fleet routes, quota policies, API keys) are NOT in the charts —
   see `docs/LIVE_STATE.md` §2 for the authoritative list of what aigw-ui/kubectl
   created outside GitOps.

### (c) Evaluating configuration quality

- `docs/LIVE_STATE.md` §3 (serving flags/resources/volumes with per-flag meaning),
  §4 (gateway policies incl. anti-spoofing header stripping), §5 (quota formulas),
  §6 (node isolation/hugepages/tuned), and especially §7 (live-vs-chart deltas).
- Chart values files carry extensive inline rationale comments (e.g.
  `charts/glm53-bundled/values.yaml` on gpu-memory-utilization headroom, DP shapes,
  EPP scorer weights; `charts/qwen38-bundled/values.yaml` on TP-shape validity).

## Object-count summary (live cluster)

Excluding the OLM `packagemanifests` catalog listings (614/ns — catalog, not deployed
objects) and point-in-time `pods_metrics`:

| Namespace / scope | Objects | Contents (highlights) |
|---|---|---|
| ns-llm-glm53 | ≈113 | LLMInferenceService, 2 Deployments (vLLM DP8×EP8 + EPP), LMCacheEngine, 2 DaemonSets, 10 Jobs, 5 HTTPRoutes / 3 AIGatewayRoutes, 4 PVCs, quota-less |
| ns-llm-judge | ≈34 | judge LLMInferenceService + EPP, storage-initializer pull, QuotaPolicy |
| ns-llm-qwen38 | ≈66 | qwen38 LLMInferenceService + EPP + LMCacheEngine, 2 DaemonSets, QuotaPolicy |
| ns-envoy-ai-gateway-system | ≈56 | Gateway, EnvoyProxy, controller, fleet route set (live-only), 2 QuotaPolicies, certs |
| ns-envoy-gateway-system | ≈75 | Envoy Gateway controller, 3-replica data plane, ratelimit service, LB Service, Route |
| ns-kserve | ≈33 | llmisvc controller v0.21.0-rc1, 13 LLMInferenceServiceConfigs (presets) |
| ns-lmcache-operator-system | ≈28 | lmcache-operator v0.5.5 |
| cluster-scoped | 25 | GatewayClass, 3 Nodes, 8 PVs, 3 StorageClasses, 5 RuntimeClasses, 5 Tuned, 3 PriorityClasses |

Per-kind counts and object names: `docs/LIVE_STATE.md` §1.

## Docs

- `LIVE_STATE.md` — live cluster state: inventory, ownership cross-reference, serving
  deep-dive, gateway objects, quotas, cluster-scoped tuning, live-vs-chart deltas.
- `SECURITY_SANITIZATION.md` — what was sanitized, what was kept, the 3-pass
  verification, and the placeholder conventions for reading this archive.
- `VERIFICATION.md` — verification pass logs (written by the export pipeline).
