# Live Cluster State — `cluster-llm-prep` (site-a)

Live-state export of the LLM serving stack, taken **2026-10-12 ~13:59 UTC** (last node
heartbeat 13:58:51Z). Every claim cites the file it was read from, relative to the archive
root: `live-cluster/<ns>/<file>` (namespace exports) and `live-cluster/cluster-scoped/`
(cluster-scoped objects). All real identifiers are replaced by the placeholder conventions
in `SECURITY_SANITIZATION.md` (site=`site-a`, cluster=`cluster-llm-prep`,
registry=`registry-internal/`, GPU nodes=`gpu-node-1`/`gpu-node-2`, util node=`util-node-1`).

The cluster is a HyperShift-hosted OpenShift 4.22 cluster (nodes carry
`hypershift.openshift.io/managed: "true"`) with 3 worker nodes: two 256-core/2 TiB B200
nodes (`gpu-node-1`, `gpu-node-2`) and one 144-core/512 GiB L4 node (`util-node-1`, which
also hosts utility/gateway workloads). See §6.

**Workloads**: GLM-5.3-Flash-NVFP4 (564G MoE) on the B200 pair via KServe
`LLMInferenceService` + llm-d router (EPP); Qwen3.8-27B-FP8 and a Qwen3.6-35B judge model
on the L4 node; Envoy AI Gateway as the single ingress; LMCache KV-offload engines per
model.

---

## 1. Inventory

`packagemanifests` (614 entries per namespace, OLM catalog listing) are omitted — they list
the whole operator catalog, not deployed objects. `pods_metrics` (PodMetrics) are point-in-time
usage snapshots, also omitted from the tables below. RBAC is duplicated per API group
(`roles_rbac…` + `roles_authorization_openshift_io…` mirrors); counts below are per file.
`ControllerRevision` objects are DaemonSet/Deployment history snapshots.

### ns-llm-glm53 — GLM-5.3 serving namespace
Source dir: `live-cluster/ns-llm-glm53/`

| Kind | n | Names |
|---|---|---|
| AIGatewayRoute | 3 | `glm53`, `glm53-anthropic-alias`, `glm53-peer` |
| AIServiceBackend | 1 | `glm53-anthropic` (schema Anthropic) |
| Backend | 1 | `glm53-ranks` (8 FQDN endpoints, ranks 8000-8007) |
| ConfigMap | 4 | `glm53-100k-script`, `glm53-cache-connection`, `kube-root-ca.crt`, `openshift-service-ca.crt` |
| ControllerRevision | 17 | (DaemonSet history: `glm53-cache`, `glm53-node-prep`) |
| DaemonSet | 2 | `glm53-cache` (LMCache engine), `glm53-node-prep` |
| Deployment | 2 | `glm53-b200-kserve` (vLLM workload), `glm53-b200-kserve-router-scheduler` (EPP) |
| Endpoints / EndpointSlice | 5 / 5 | (for the 5 Services) |
| HTTPRoute | 5 | `glm53`, `glm53-anthropic-alias`, `glm53-b200-kserve-route`, `glm53-peer`, `glm53-peer-health` |
| HTTPRouteFilter | 6 | `ai-eg-host-rewrite-{glm53,glm53-anthropic-alias,glm53-peer}`, `ai-eg-route-not-found-response-{glm53,glm53-anthropic-alias,glm53-peer}` |
| InferenceObjective | 1 | `best-effort` (llm-d.ai/v1alpha1) |
| InferencePool | 1 + 1 | `glm53-b200-inference-pool` (`inference.networking.k8s.io/v1` and `x-k8s.io/v1alpha1` API versions) |
| Job | 10 | `glm53-pull-gpu-node-1`, `glm53-pull-gpu-node-2`, `glm53-pull-flash-gpu-node-1`, `glm53-pull-flash-gpu-node-2`, `glm53-flash-mtpfix-gpu-node-1`, `glm53-flash-mtpfix-gpu-node-2`, `glm53-flash-bucket-repair`, `glm53-flash-cfg-check`, `glm53-flash-s3-search2`, `glm53-flash-s3-search3` (names embed the target node; sanitized here) |
| LLMInferenceService | 1 | `glm53-b200` |
| LMCacheEngine | 1 | `glm53-cache` |
| PrometheusRule / ServiceMonitor | 1 / 1 | `glm53-cache` (engine metrics) |
| PVC | 4 | `glm53-cache` 300Gi, `glm53-cache-l2` 2500Gi, `glm53-models` 1200Gi (all `local-static`), `glm53-model` 1Ti (`lvms-vg1`, live-only, see §2/§7) |
| ReplicaSet | 19 | (Deployment history) |
| Role / RoleBinding | 4 / 8 | `glm53-b200-epp-role`, `prometheus-k8s`, `use-glm53-model-serving-scc`, `use-privileged-scc` (+ OpenShift auto RBAC) |
| Secret | 9 | `glm53-s3` (S3 creds, out-of-band), `glm53-internal-key` (API key), `glm53-b200-kserve-self-signed-certs` (kserve-generated TLS), 6× dockercfg |
| SecurityPolicy | 1 | `glm53-b200-kserve-route-internal` (API-key auth on the kserve HTTPRoute) |
| Service | 5 | `glm53-b200-epp-service` (9002/9003/9090/5557), `glm53-b200-kserve-workload-svc` (:8000), `glm53-b200-ranks-svc` (8000-8007), `glm53-cache` (5555/8080), `glm53-cache-metrics` (8080) |
| ServiceAccount | 6 | `s3sa`, `glm53-cache`, `glm53-node-prep`, `builder`, `default`, `deployer` |

### ns-llm-judge — Qwen3.6 judge model
Source dir: `live-cluster/ns-llm-judge/`

| Kind | n | Names |
|---|---|---|
| AIGatewayRoute | 1 | `qwen36-judge` |
| AIServiceBackend | 1 | `qwen36-judge-openai` (schema OpenAI) |
| Backend | 1 | `qwen36-judge-workload` (1 FQDN endpoint :8000) |
| ConfigMap | 2 | `kube-root-ca.crt`, `openshift-service-ca.crt` |
| Deployment | 2 | `qwen36-judge-kserve` (workload), `qwen36-judge-kserve-router-scheduler` (EPP) |
| Endpoints / EndpointSlice | 2 / 2 | (for the 2 Services) |
| HTTPRoute | 2 | `qwen36-judge`, `qwen36-judge-kserve-route` |
| HTTPRouteFilter | 2 | `ai-eg-host-rewrite-qwen36-judge`, `ai-eg-route-not-found-response-qwen36-judge` |
| InferencePool | 1 + 1 | `qwen36-judge-inference-pool` (both API groups) |
| LLMInferenceService | 1 | `qwen36-judge` |
| QuotaPolicy | 1 | `judge` (live-only, aigw-ui) |
| ReplicaSet | 3 | (Deployment history) |
| Role / RoleBinding | 3 / 6 | `qwen36-judge-epp-role`, `prometheus-k8s`, `use-qwen36-judge-model-serving-scc` |
| Secret | 6 | `judge-s3` (out-of-band S3 creds), `qwen36-judge-kserve-self-signed-certs`, 4× dockercfg |
| Service | 2 | `qwen36-judge-epp-service`, `qwen36-judge-kserve-workload-svc` |
| ServiceAccount | 4 | `s3sa`, `builder`, `default`, `deployer` |

### ns-llm-qwen38 — Qwen3.8 model
Source dir: `live-cluster/ns-llm-qwen38/`

| Kind | n | Names |
|---|---|---|
| AIGatewayRoute | 1 | `qwen38` |
| AIServiceBackend | 1 | `qwen38-anthropic` (schema Anthropic) |
| Backend | 1 | `qwen38-anthropic-workload` (1 FQDN endpoint :8000) |
| ConfigMap | 3 | `qwen38-cache-connection`, `kube-root-ca.crt`, `openshift-service-ca.crt` |
| ControllerRevision | 14 | (DaemonSet history) |
| DaemonSet | 2 | `qwen38-cache` (LMCache engine), `qwen38-node-prep` |
| Deployment | 2 | `qwen38-l4-kserve` (workload), `qwen38-l4-kserve-router-scheduler` (EPP) |
| Endpoints / EndpointSlice | 4 / 4 | (for the 4 Services) |
| HTTPRoute | 2 | `qwen38`, `qwen38-l4-kserve-route` |
| HTTPRouteFilter | 2 | `ai-eg-host-rewrite-qwen38`, `ai-eg-route-not-found-response-qwen38` |
| InferencePool | 1 + 1 | `qwen38-l4-inference-pool` (both API groups) |
| Job | 1 | `qwen38-pull-util-node-1` (model pull; name embeds node, sanitized) |
| LLMInferenceService | 1 | `qwen38-l4` |
| LMCacheEngine | 1 | `qwen38-cache` |
| PrometheusRule / ServiceMonitor | 1 / 1 | `qwen38-cache` |
| PVC | 3 | `qwen38-cache` 150Gi, `qwen38-cache-l2` 1000Gi, `qwen38-models` 200Gi (all `qwen38-local-static`) |
| QuotaPolicy | 1 | `qwen3-8-27b-fp8` (live-only, aigw-ui) |
| ReplicaSet | 12 | (Deployment history) |
| Role / RoleBinding | 4 / 8 | `qwen38-l4-epp-role`, `prometheus-k8s`, `use-privileged-scc`, `use-qwen38-model-serving-scc` |
| Secret | 8 | `qwen38-s3` (out-of-band), `qwen38-l4-kserve-self-signed-certs`, 6× dockercfg |
| Service | 4 | `qwen38-l4-epp-service`, `qwen38-l4-kserve-workload-svc`, `qwen38-cache`, `qwen38-cache-metrics` |
| ServiceAccount | 6 | `s3sa`, `qwen38-cache`, `qwen38-node-prep`, `builder`, `default`, `deployer` |

### ns-envoy-ai-gateway-system — Envoy AI Gateway control plane + fleet route
Source dir: `live-cluster/ns-envoy-ai-gateway-system/`

| Kind | n | Names |
|---|---|---|
| AIGatewayRoute | 1 | `fleet-glm-5-3` (live-only, aigw-ui) |
| AIServiceBackend | 2 | `fleet-glm-5-3`, `fleetbe-glm-5-3` (live-only, aigw-ui) |
| Backend | 1 | `fleet-glm-5-3` (live-only; self-loop to the peers listener, see §4) |
| BackendTrafficPolicy | 1 | `fleet-glm-5-3` (live-only; consistent-hash, see §4) |
| Certificate / CertificateRequest | 3 / 3 | `llm-peer-client`, `llm-peer-server`, `self-signed-cert-for-mutating-webhook` (+ their CRs) |
| ClientTrafficPolicy | 2 | `client-buffer-limit` (chart), `peers` (chart; mTLS on peers listener) |
| ConfigMap | 3 | `llm-peer-ca` (fleet CA bundle), `kube-root-ca.crt`, `openshift-service-ca.crt` |
| Deployment | 1 | `ai-gateway-controller` (v1.2.0-patched.1) |
| Endpoints / EndpointSlice | 1 / 1 | `ai-gateway-controller` |
| EnvoyPatchPolicy | 1 | `fleet-glm-5-3-retry` (live-only; xDS JSON patches, see §4) |
| EnvoyProxy | 1 | `envoy-ai-gateway` (data-plane tuning, 3 replicas) |
| Gateway | 1 | `envoy-ai-gateway` (2 listeners, see §4) |
| HTTPRoute | 1 | `fleet-glm-5-3` (live-only) |
| HTTPRouteFilter | 2 | `ai-eg-host-rewrite-fleet-glm-5-3`, `ai-eg-route-not-found-response-fleet-glm-5-3` |
| Issuer | 1 | `self-signed-issuer-for-mutating-webhook` |
| Lease | 1 | `envoy-ai-gateway-controller` |
| QuotaPolicy | 2 | `glm-5-3`, `fleetbe-glm-5-3` (live-only, aigw-ui; `fleetbe` in shadowMode) |
| ReplicaSet | 4 | (controller history) |
| Role / RoleBinding | 1 / 5 | `prometheus-k8s` (+ OpenShift auto RBAC incl. `nonroot-v2` SCC binding) |
| Secret | 9 | `aigw-ui-api-keys` (live-only), `ai-gateway-controller-mcp-session-encryption`, `llm-peer-client`, `llm-peer-server`, `self-signed-cert-for-mutating-webhook`, 4× dockercfg |
| SecurityPolicy | 1 | `aigw-ui-api-key-auth` (live-only; API-key auth on fleet route, see §4) |
| Service | 1 | `ai-gateway-controller` |
| ServiceAccount | 4 | `ai-gateway-controller`, `builder`, `default`, `deployer` |

### ns-envoy-gateway-system — Envoy Gateway + data plane
Source dir: `live-cluster/ns-envoy-gateway-system/`

| Kind | n | Names |
|---|---|---|
| ConfigMap | 4 | `envoy-envoy-ai-gateway-system-envoy-ai-gateway-04213612` (Envoy bootstrap), `envoy-gateway-config`, `kube-root-ca.crt`, `openshift-service-ca.crt` |
| Deployment | 3 | `envoy-gateway` (EG controller v1.9.2), `envoy-ai-gateway-ratelimit` (quota enforcement service), `envoy-envoy-ai-gateway-system-envoy-ai-gateway-04213612` (data-plane Envoy, 3 replicas) |
| Endpoints / EndpointSlice | 5 / 5 | (for the 5 Services) |
| Lease | 2 | `5b9825d2.gateway.envoyproxy.io`, `envoy-ai-gateway-controller` |
| PodDisruptionBudget | 1 | `envoy-envoy-ai-gateway-system-envoy-ai-gateway-04213612` (minAvailable 1) |
| ReplicaSet | 12 | (Deployment history) |
| Role / RoleBinding | 4 / 9 | (EG controller RBAC + OpenShift auto RBAC) |
| Route (OpenShift) | 1 | `envoy-ai-gateway` (edge TLS → LB service http-80) |
| Secret | 17 | `envoy-ai-quota-redis-client` (Redis creds+CA, Argo `IgnoreExtraneous`/`Prune=false`), `envoy-gateway`, `envoy`, `envoy-oidc-hmac`, `envoy-rate-limit`, EG-generated infra secrets for extproc config (incl. per-route `glm53-kserve-llm-glm53*`), dockercfg |
| Service | 5 | `envoy-ai-gateway` (**LoadBalancer**, 80/8443, `externalTrafficPolicy: Local`), `envoy-ai-gateway-extproc-metrics` (:1064), `envoy-ai-gateway-proxy-metrics` (:19001), `envoy-ai-gateway-ratelimit` (gRPC :8081), `envoy-gateway` (18000/18001/18002/19001/9443) |
| ServiceAccount | 6 | (EG controller, data plane, ratelimit, builder, default, deployer) |

### ns-kserve — KServe LLMInferenceService controller
Source dir: `live-cluster/ns-kserve/`

| Kind | n | Names |
|---|---|---|
| Certificate / CertificateRequest | 1 / 1 | `llmisvc-webhook-server-cert` (+ CR) |
| ConfigMap | 3 | `inferenceservice-config` (17 keys: deploy/ingress/router/storageInitializer/…), `kube-root-ca.crt`, `openshift-service-ca.crt` |
| Deployment | 1 | `llmisvc-controller-manager` (kserve `llmisvc-controller:v0.21.0-rc1`, `--leader-elect`) |
| Issuer | 1 | (self-signed issuer for the webhook cert) |
| LLMInferenceServiceConfig | 13 | `kserve-config-llm-{decode-template,decode-worker-data-parallel,prefill-template,prefill-worker-data-parallel,router-route,scheduler,scheduler-eppconfig-default,scheduler-eppconfig-default-pd,scheduler-latency-predictor,template,tokenizer,tracing,worker-data-parallel}` |
| Role / RoleBinding | 1 / 5 | `llmisvc-leader-election-role` |
| Secret | 5 | `llmisvc-webhook-server-cert`, 4× dockercfg |
| Service | 2 | `llmisvc-controller-manager-service`, `llmisvc-webhook-server-service` |
| ServiceAccount | 4 | `llmisvc-controller-manager`, `builder`, `default`, `deployer` |

### ns-lmcache-operator-system — LMCache operator
Source dir: `live-cluster/ns-lmcache-operator-system/`

| Kind | n | Names |
|---|---|---|
| Certificate / CertificateRequest | 1 / 1 | `webhook-server-cert` (+ CR) |
| ConfigMap | 2 | `kube-root-ca.crt`, `openshift-service-ca.crt` |
| Deployment | 1 | `lmcache-operator-controller-manager` (`lmcache-operator:v0.5.5`) |
| Issuer | 1 | (self-signed issuer for the webhook cert) |
| Role / RoleBinding | 1 / 4 | `lmcache-operator-leader-election-role` |
| Secret | 5 | `webhook-server-cert`, 4× dockercfg |
| Service | 2 | `lmcache-operator-controller-manager-metrics-service`, `lmcache-operator-webhook-service` |
| ServiceAccount | 4 | `lmcache-operator-controller-manager`, `builder`, `default`, `deployer` |

### cluster-scoped
Source dir: `live-cluster/cluster-scoped/`

| Kind | n | Names |
|---|---|---|
| GatewayClass | 1 | `envoy-ai-gateway` |
| Node | 3 | `gpu-node-1`, `gpu-node-2` (B200), `util-node-1` (L4) — see §6 |
| PersistentVolume | 8 | `glm53-cache`, `glm53-cache-l2`, `glm53-models`, `qwen38-cache`, `qwen38-cache-l2`, `qwen38-models` (local-path), 2× `pvc-*` (`lvms-vg1`, incl. the 1Ti `glm53-model`) — see §6 |
| PriorityClass | 3 | `openshift-user-critical`, `system-cluster-critical`, `system-node-critical` |
| RuntimeClass | 5 | `nvidia`, `nvidia-cdi`, `nvidia-legacy`, `performance-gpu-hpc-performanceprofile-extras-b200`, `performance-gpu-hpc-performanceprofile-extras-l4` |
| StorageClass | 3 | `local-static`, `qwen38-local-static` (no-provisioner, Retain), `lvms-vg1` (topolvm, xfs/vg1) |
| Tuned | 5 | `default`, `gpu-hpc-tuned-extras-b200-*`, `gpu-hpc-tuned-extras-l4-*`, `openshift-node-performance-gpu-hpc-performanceprofile-extras-b200-*`, `openshift-node-performance-gpu-hpc-performanceprofile-extras-l4-*` |

Every model/gateway namespace also exports one ClusterServiceVersion:
`nvidia-maintenance-operator.v26.4.0` (OLM subscription status object; the operator's own
pods are not part of these namespaces' exports).

**Object-count summary** (excluding packagemanifests/PodMetrics; RBAC counted per API
group): glm53 ≈ 113, judge ≈ 34, qwen38 ≈ 66, envoy-ai-gateway-system ≈ 56,
envoy-gateway-system ≈ 75, kserve ≈ 33, lmcache-operator-system ≈ 28, cluster-scoped = 25.
Granular counts per kind are in the tables above.

---

## 2. Cross-reference: live object → chart / Argo CD app

Ownership is readable from three markers on every live object:

1. `argocd.argoproj.io/tracking-id: gitops-popai_popai-<cluster>-<app>-deploy:<group>/<kind>:<ns>/<name>`
   — the Argo CD Application (project `popai`) that rendered the object.
2. `helm.sh/chart: <chart>-<version>` + `app.kubernetes.io/instance` — the Helm chart.
3. `ownerReferences` — controller-generated objects (KServe, cert-manager, lmcache-operator,
   Envoy Gateway).

### Argo CD applications (tracking-id prefix → chart)

| App (tracking prefix `popai-<cluster>-<app>-deploy`) | Chart | Manages (live namespaces) |
|---|---|---|
| `glm53-deploy` | `glm53-bundled-0.1.0` | everything labelled `instance: glm53` in `llm-glm53`: LLMInferenceService, LMCacheEngine, DaemonSets, PVCs/PVs, jobs, AIGatewayRoutes `glm53`+`glm53-peer`, Backend/AIServiceBackend, SecurityPolicy, SCC-use roles, ServiceAccounts |
| `glm53-anthropic-alias` | `glm53-anthropic-alias-0.1.0` | AIGatewayRoute/HTTPRoute/filters `glm53-anthropic-alias` in `llm-glm53` |
| `qwen36-judge-deploy` | `qwen36-judge-0.2.2` | `llm-judge` objects (LLMInferenceService `qwen36-judge`, AIGatewayRoute, Backend/AIServiceBackend, SCC-use role, SAs) |
| `qwen38-deploy` | `qwen38-bundled-0.2.6` | `llm-qwen38` objects (LLMInferenceService `qwen38-l4`, LMCacheEngine, DaemonSets, PVCs, AIGatewayRoute, Backend/AIServiceBackend, prometheus rule/monitor) |
| `envoy-ai-deploy` | `envoy-ai-gateway-openshift-0.1.0` | `envoy-ai-gateway-system` + `envoy-gateway-system`: GatewayClass, Gateway, EnvoyProxy, ClientTrafficPolicies, controller Deployment, ratelimit Deployment, certs/issuers, OpenShift Route, LB Service (via EnvoyProxy), SCC RoleBindings |

App-of-apps source: `gitops/app-of-apps/operators/<app>/` (+ per-site values under
`gitops/app-of-apps/sites/site-a/prep/mces/<mce>/cluster-llm-prep/<app>/values.yaml`).

### Controller-generated (ownerReferences, not Helm)

- **KServe llmisvc controller** (`ns-kserve`): per LLMInferenceService it created the
  workload Deployment, EPP scheduler Deployment, `*-epp-service` + `*-kserve-workload-svc`
  (+ `glm53-b200-ranks-svc` from the ranks spec) Services, InferencePools (both API
  groups), `*-kserve-route` HTTPRoutes, `*-self-signed-certs` Secrets, ReplicaSets,
  Endpoints/EndpointSlices, `*-epp-role` roles. Example owner chain in
  `live-cluster/ns-llm-glm53/deployments_apps.yaml` (ownerRef → LLMInferenceService
  `glm53-b200`).
- **cert-manager**: CertificateRequests and the `llm-peer-*` / webhook Secrets
  (ownerRef → Certificate).
- **lmcache-operator**: `glm53-cache` / `qwen38-cache` DaemonSet pods + metrics Service
  (ownerRef → LMCacheEngine).
- **Envoy Gateway**: data-plane Deployment/Service/PDB/SA in `envoy-gateway-system`
  (`app.kubernetes.io/managed-by: envoy-gateway`, owning-gateway labels), EG infra Secrets.
- **OpenShift**: `kube-root-ca.crt`/`openshift-service-ca.crt` ConfigMaps, `*-dockercfg-*`
  Secrets, `system:*`/`builder`/`deployer` RoleBindings, Endpoints/EndpointSlices.

### Live-only objects NOT owned by any chart

Labelled `app.kubernetes.io/managed-by: aigw-ui`, no tracking-id, no ownerReferences —
created by the fleet management UI ("aigw-ui"), operator of the cross-site fleet:

| Object | Namespace | Notes |
|---|---|---|
| AIGatewayRoute `fleet-glm-5-3` | envoy-ai-gateway-system | fleet entry route for glm-5.3 (see §4) |
| HTTPRoute `fleet-glm-5-3` + 2 HTTPRouteFilters | envoy-ai-gateway-system | translated from the AIGatewayRoute |
| AIServiceBackend `fleet-glm-5-3`, `fleetbe-glm-5-3` | envoy-ai-gateway-system | `fleetbe` carries `x-llm-d-inference-objective: best-effort` |
| Backend `fleet-glm-5-3` | envoy-ai-gateway-system | loopback to the local peers listener (see §4) |
| BackendTrafficPolicy `fleet-glm-5-3` | envoy-ai-gateway-system | session hash + health check (see §4) |
| EnvoyPatchPolicy `fleet-glm-5-3-retry` | envoy-ai-gateway-system | retry xDS patches (see §4) |
| QuotaPolicy `glm-5-3`, `fleetbe-glm-5-3` | envoy-ai-gateway-system | `fleetbe` shadowMode: true (see §5) |
| QuotaPolicy `judge`, `qwen3-8-27b-fp8` | llm-judge / llm-qwen38 | per-user budgets (see §5) |
| SecurityPolicy `aigw-ui-api-key-auth` + Secret `aigw-ui-api-keys` | envoy-ai-gateway-system | API-key auth for the fleet route (see §4) |
| InferenceObjective `best-effort` | llm-glm53 | llm-d.ai/v1alpha1, priority -1, targets the glm53 InferencePool |

Other live-only objects (no labels/owner at all — kubectl-applied):

| Object | Namespace | Notes |
|---|---|---|
| PVC `glm53-model` (1Ti, `lvms-vg1`) | llm-glm53 | pre-dates the chart's own `glm53-models` PVC; volumeName `pvc-7cbbc0cf-…` bound to `gpu-node-1` (see §7) |
| Secret `glm53-s3`, `judge-s3`, `qwen38-s3` | per model ns | S3 credentials, deliberately out-of-band (chart `s3.create: false`) |
| Secret `glm53-internal-key` | llm-glm53 | API key for SecurityPolicy `glm53-b200-kserve-route-internal` |
| ConfigMap `glm53-100k-script` | llm-glm53 | 100k-token benchmark harness script (no owner) |
| Jobs `glm53-flash-{mtpfix,bucket-repair,cfg-check,s3-search*}` (6 of 10) | llm-glm53 | 2026-10-12 MTP-weight repair jobs pulling `model_mtp.safetensors` from the S3 bucket (see §7) |
| Secret `envoy-ai-quota-redis-client` | envoy-gateway-system | Argo-tracked but `IgnoreExtraneous` + `Prune=false` — deliberately un-prunable (documented in `gitops/app-of-apps/sites/site-a/prep/mces/<mce>/cluster-llm-prep/envoy-ai/values.yaml`) |

---

## 3. Serving deployment deep-dive

### 3.1 GLM-5.3 workload — Deployment `glm53-b200-kserve` (ns-llm-glm53)

Generated by the KServe controller from LLMInferenceService `glm53-b200`
(`live-cluster/ns-llm-glm53/llminferenceservices_serving_kserve_io.yaml`); container spec
from `live-cluster/ns-llm-glm53/deployments_apps.yaml`.

| Field | Value |
|---|---|
| Replicas / strategy | 2 (one pod per B200 node); RollingUpdate `maxSurge: 0`, `maxUnavailable: 1` |
| Image | `registry-internal/vllm/vllm-openai@sha256:464346c4…` (digest-pinned LMCache-enabled build; differs from the chart's `vllm-openai:v0.30.0` tag, see §7) |
| nodeSelector | `nvidia.com/gpu.product: NVIDIA-B200` |
| runtimeClassName | `performance-gpu-hpc-performanceprofile-extras-b200` (isolated CPUs + hugepages, §6) |
| ServiceAccount | `s3sa` (SCC `glm53-model-serving` via role `use-glm53-model-serving-scc`) |
| Termination | gracePeriod 300s; preStop `sleep 15` |
| Resources | requests 96 CPU / 512Gi mem / 8 GPU / 16Gi hugepages-1Gi; limits 192 CPU / 2000Gi / 8 GPU / 16Gi hugepages-1Gi |

Command (from the KServe `kserve-config-llm-template` preset, merged into the CR): a bash
script that (a) if `KSERVE_INFER_ROCE=true` discovers active RoCE v2 HCAs from sysfs and
exports `NCCL_IB_HCA`/`NVSHMEM_HCA_LIST`; (b) version-gates optional vLLM flags
(ACCESS_LOG, SHUTDOWN_TIMEOUT, KV_TRANSFER args — upstream PR references in the script);
(c) `exec vllm serve /mnt/models --served-model-name glm-5.3 publishers/llm-glm53/models/glm-5.3 --port 8000`.
Full text in `deployments_apps.yaml` (container command) and
`live-cluster/ns-kserve/llminferenceserviceconfigs_serving_kserve_io.yaml`
(`kserve-config-llm-template`).

vLLM args (per-flag meaning inferred from name/upstream vLLM semantics):

| Arg | Meaning |
|---|---|
| `--data-parallel-size=8` / `--data-parallel-size-local=8` | 8 DP engines per pod, all local (single node, NVLink) |
| `--data-parallel-multi-port-external-lb` | one API server per DP rank on ports 8000-8007; ranks become individual InferencePool endpoints so the EPP balances at rank level |
| `--data-parallel-supervisor-port=8208` | DP supervisor aggregates `/health` `/readyz` on 8208 (probe target) |
| `--enable-expert-parallel` | MoE expert parallelism (EP8 with DP8) |
| `--all2all-backend=allgather_reducescatter` | all2all (all-to-all) backend used for EP token dispatch |
| `--kv-cache-dtype=fp8` | FP8 KV cache (halves KV memory) |
| `--gpu-memory-utilization=0.85` | fraction of GPU memory vLLM may claim (0.85 live vs 0.90 chart, §7) |
| `--max-model-len=262144` | 256k context window |
| `--max-num-seqs=512` | max concurrent sequences (per pod aggregate; 512 live vs 64/rank chart, §7) |
| `--max-num-batched-tokens=32768` | chunked-prefill budget per engine step (32768 live vs 16384 chart, §7) |
| `--enable-prefix-caching` | automatic prefix cache (KV reuse) |
| `--enable-chunked-prefill` | split long prefills into chunks |
| `--load-format=auto` | checkpoint format autodetection |
| `--per-request-spec-decode-metrics=summary` | spec-decode acceptance metrics per request, summary granularity |
| `--kv-cache-metrics` | KV block lifetime/idle/reuse histograms |
| `--enable-prompt-tokens-details` | report cached prompt tokens in usage (gateway billing input) |
| `--enable-force-include-usage` | force usage chunk in streamed responses (gateway billing input) |
| `--speculative-config.method=mtp` + `--speculative-config.num_speculative_tokens=3` | MTP speculative decoding, 3 draft tokens (3 live vs 5 chart, §7) |
| `--reasoning-parser=glm45` | reasoning-content parser for the GLM family |
| `--tool-call-parser=glm47` + `--enable-auto-tool-choice` | GLM tool-call parsing |
| `--trust-remote-code` | allow model's custom code |
| `--kv-transfer-config {"kv_connector":"LMCacheMPConnector", …}` | KV offload to the LMCache engine: `lmcache.mp.host=tcp://glm53-cache.llm-glm53.svc.cluster.local`, port 5555, `isolated_ipc: true`, `kv_role: kv_both` (both producer and consumer — cross-pod prefix sharing). Replaces the chart's CPU-offload connector (see §7) |

Env (notable): `NCCL_IB_DISABLE=1`, `NCCL_P2P_LEVEL=NVL` (intra-node NVLink transport,
no RDMA), `NVSHMEM_REMOTE_TRANSPORT=none`, `NVSHMEM_IB_ENABLE_IBGDA=0`,
`VLLM_USE_V1=1`, `VLLM_USE_DEEP_GEMM=1`, `VLLM_DEEP_GEMM_WARMUP=skip`,
`VLLM_LOGGING_LEVEL=INFO`, `PYTHONHASHSEED=0`, `OMP_NUM_THREADS=16`,
`HF_HUB_OFFLINE=1` / `TRANSFORMERS_OFFLINE=1` (air-gap), `VLLM_ENGINE_READY_TIMEOUT_S=3600`,
JIT caches on the cache PVC (`VLLM_CACHE_ROOT=/cache/vllm`, `DG_JIT_CACHE_DIR`,
`TRITON_CACHE_DIR`, `TORCHINDUCTOR_CACHE_DIR`, `TORCHINDUCTOR_FX_GRAPH_CACHE=1`,
`FLASHINFER_WORKSPACE_BASE`, `HF_HOME=/cache/hf`), `HF_HUB_CACHE=/models`.

Volumes / mounts:

| Volume | Source | Mount | Purpose |
|---|---|---|---|
| `compile-cache` | PVC `glm53-cache` (300Gi local-static, both B200 nodes) | `/cache` | persistent vLLM/DeepGEMM/Triton/Inductor JIT caches |
| `kserve-pvc-source` | PVC `glm53-models` (1200Gi local-static), subPath `GLM-5.3-Flash-NVFP4` | `/mnt/models` | model weights (per-node copy; live subPath differs from chart `GLM-5.3`, §7) |
| `dshm` | emptyDir `medium: Memory`, sizeLimit 600Gi | `/dev/shm` | vLLM CPU-offload tmpfs (8×64Gi per-rank offload windows) |
| `hugepages` | emptyDir `medium: HugePages`, sizeLimit 16Gi | `/dev/hugepages` | hugepage-backed allocations (pod requests 16Gi hugepages-1Gi) |
| `tls-certs` | Secret `glm53-b200-kserve-self-signed-certs` | `/var/run/kserve/tls` | kserve self-signed TLS |
| `home`, `tmp-dir`, `model-cache` | emptyDir | `/home`, `/tmp`, `/models` | scratch |

Probes (all on supervisor port 8208): startup `/health` (180×10s = 30min cold-boot budget:
safetensors load + DeepGEMM JIT + graph capture), readiness `/readyz` (5×10s), liveness
`/health` (5×30s).

### 3.2 GLM-5.3 EPP scheduler — Deployment `glm53-b200-kserve-router-scheduler`

KServe-generated endpoint-picker (llm-d-router) for InferencePool `glm53-b200-inference-pool`;
strategy `Recreate`.

| Field | Value |
|---|---|
| Image | `registry-internal/kserve/llm-d/llm-d-router-endpoint-picker:v0.10.0` |
| Args | `/app/epp --pool-name glm53-b200-inference-pool --pool-namespace llm-glm53 --grpc-port 9002 --grpc-health-port 9003 --config-text <EndpointPickerConfig>` |
| Ports | 9002 (gRPC picker), 9003 (gRPC health), 9090 (metrics), 5557 (zmq) |
| Resources | requests 1 CPU / 2Gi; limits 6 CPU / 16Gi |

`--config-text` (EndpointPickerConfig, verbatim): plugins `single-profile-handler`,
`approx-prefix-cache-producer`, `inflight-load-producer`, `prefix-cache-scorer`,
`active-request-scorer`, `token-load-scorer`, `max-score-picker`; default scheduling
profile weights: active-request-scorer **3**, token-load-scorer **1**,
prefix-cache-scorer **3** (chart default is 1 — §7), max-score-picker. The
inflight-load-producer counts requests the EPP itself dispatched (immune to the DP8
engine-label duplication on vLLM /metrics); approx-prefix-cache-producer feeds the
prefix-cache-scorer (per chart comments in `charts/glm53-bundled/values.yaml`).

The EPP image override lives in the KServe preset
`kserve-config-llm-scheduler` (`live-cluster/ns-kserve/llminferenceserviceconfigs_serving_kserve_io.yaml`):
`spec.router.scheduler.template.containers[0].image` points at the internal-registry
mirror — the default `ghcr.io` image is unreachable air-gapped (documented as an
out-of-band prerequisite in `charts/glm53-bundled/README.md`).

### 3.3 InferencePool + EPP Service

`live-cluster/ns-llm-glm53/inferencepools_inference_networking_k8s_io.yaml` (and the
x-k8s.io twin): pool `glm53-b200-inference-pool`, appProtocol http,
`endpointPickerRef: Service/glm53-b200-epp-service:9002` (`failureMode: FailOpen`),
selector `app.kubernetes.io/name: glm53-b200, kserve.io/component: workload`,
targetPorts 8000-8007 (one per DP rank). Service `glm53-b200-epp-service` (ClusterIP)
exposes 9002/9003/9090/5557 against the scheduler pods; `glm53-b200-ranks-svc` exposes
rank ports 8000-8007 (used by the Anthropic Backend, §4);
`glm53-b200-kserve-workload-svc` exposes :8000 (kserve router path).

### 3.4 Judge workload — Deployment `qwen36-judge-kserve` (ns-llm-judge)

From `live-cluster/ns-llm-judge/deployments_apps.yaml` + `llminferenceservices_serving_kserve_io.yaml`.

| Field | Value |
|---|---|
| Replicas / strategy | 1; RollingUpdate 25%/25% |
| Image | `registry-internal/vllm/vllm-openai:v0.30.0` |
| nodeSelector | `nvidia.com/gpu.product: NVIDIA-L4` (no runtimeClassName) |
| Resources | requests 16 CPU / 64Gi / 2 GPU; limits 32 CPU / 128Gi / 2 GPU |
| initContainer | `storage-initializer` (`registry-internal/kserve/kserve/storage-initializer:v0.21.0-rc1`): pulls `s3://llms/Qwen/Qwen3.6-35B-A3B-FP8` into an emptyDir `/mnt/models` (no PVC — model re-downloads per pod restart) |
| Args | `--max-model-len=16384 --max-num-seqs=128 --reasoning-parser=qwen3 --enable-prefix-caching --enable-prompt-tokens-details --enable-force-include-usage --default-chat-template-kwargs='{"enable_thinking": false}' --limit-mm-per-prompt='{"image":0,"video":0}' --trust-remote-code` (thinking disabled server-side; multimodal inputs disabled; parallelism comes from `spec.parallelism.tensor=2`, rendered as `--tensor-parallel-size=2` by the preset, not duplicated in args) |
| Volumes | emptyDirs only (home, dshm, model-cache, tmp-dir, provision location) + kserve TLS secret |

Judge chart source: `charts/qwen36-judge/` (values match live: same model, image, args).

### 3.5 Qwen3.8 workload — Deployment `qwen38-l4-kserve` (ns-llm-qwen38)

From `live-cluster/ns-llm-qwen38/deployments_apps.yaml` + `llminferenceservices_serving_kserve_io.yaml`.

| Field | Value |
|---|---|
| Replicas / strategy | 1 (single L4 node); RollingUpdate `maxSurge: 0`, `maxUnavailable: 1` |
| Image | `registry-internal/lmcache/lmcache/vllm-openai:v0.5.5` (LMCache-enabled vLLM build; engine must match, see 3.6) |
| nodeSelector / runtime | `NVIDIA-L4` / `performance-gpu-hpc-performanceprofile-extras-l4` |
| Resources | requests 48 CPU / 64Gi / 4 GPU; limits 96 CPU / 128Gi / 4 GPU |
| Args | `--tensor-parallel-size=4 --data-parallel-size=1 --max-model-len=65536 --kv-cache-dtype=fp8_e4m3 --gpu-memory-utilization=0.90 --max-num-seqs=32 --max-num-batched-tokens=8192 --kv-cache-metrics --enable-prefix-caching --enable-prompt-tokens-details --enable-force-include-usage --enable-chunked-prefill --speculative-config.method=mtp --speculative-config.num_speculative_tokens=2 --per-request-spec-decode-metrics=summary --reasoning-parser=qwen3 --tool-call-parser=qwen3_xml --enable-auto-tool-choice --trust-remote-code --kv-transfer-config {"kv_connector":"LMCacheMPConnector", host tcp://qwen38-cache.llm-qwen38.svc.cluster.local:5555, isolated_ipc, kv_role kv_both}` |
| Volumes | PVC `qwen38-cache` (compile cache, 150Gi) + PVC `qwen38-models` (subPath model dir) + emptyDirs + kserve TLS |

Chart source `charts/qwen38-bundled/values.yaml` documents the shape rationale: TP4/DP1
(TP must divide 24 attn heads AND 4 KV heads; TP4 halves the per-GPU weight shard for
single-stream decode on 24GiB L4s), internal DP LB (external multi-port LB is MoE-gated,
this model is not MoE), MTP k=2 conservative vs glm53's k=3.

### 3.6 LMCache engines (KV offload)

`live-cluster/ns-llm-glm53/lmcacheengines_lmcache_lmcache_ai.yaml` +
`live-cluster/ns-llm-qwen38/lmcacheengines_lmcache_lmcache_ai.yaml`; rendered as DaemonSets
(`glm53-cache`, `qwen38-cache`) by the lmcache-operator (image `lmcache-operator:v0.5.5`).

| Field | glm53-cache | qwen38-cache |
|---|---|---|
| Placement | DaemonSet on B200 nodes | single instance on util-node-1 |
| PriorityClass | `openshift-user-critical` | (default) |
| L1 (RAM) | 1000Gi | 200Gi |
| L2 (disk) | POSIX `nixl_store_dynamic` on PVC `glm53-cache-l2` (2500Gi, cap 2200Gi, LRU) | PVC `qwen38-cache-l2` (1000Gi, cap 900Gi) |
| Chunk size | 256 tokens | 1600 tokens |
| Hash | blake3 | blake3 |
| IPC | isolated (`isolated_ipc`) | isolated |
| Image | lmcache `v0.5.5` build | same |
| Exposure | Service 5555 (server) + 8080 (prometheus) + ServiceMonitor `glm53-cache` + PrometheusRule `glm53-cache` | same (`qwen38-cache*`) |

Workloads connect via `--kv-transfer-config` (see 3.1/3.5) and the
`glm53-cache-connection` / `qwen38-cache-connection` ConfigMaps. Both engines and both
vLLM sides run the same lmcache build (private ZMQ/CUDA-IPC protocol — lockstep
requirement documented in `charts/qwen38-bundled/values.yaml`).

### 3.7 node-prep DaemonSets (`glm53-node-prep`, `qwen38-node-prep`)

`live-cluster/ns-llm-glm53/daemonsets_apps.yaml` (+ qwen38 twin). Privileged DaemonSet
(SA with `use-privileged-scc`) that on each target node creates and keeps mounted manual
LVM logical volumes from the node VG `vg1` at `/var/mnt/llm/{models,cache,lmcache-l2}`
(LV names `llm-models`, `llm-cache`, `llm-l2`), relabeled `container_file_t`, idempotent
60s loop, survives reboots (this hosted cluster has no manageable MCO/MachineConfig —
rationale in `charts/glm53-bundled/README.md`). The glm53 variant also seeds flashinfer
trtllm-gen cubins into the cache LV from a sidecar container (`cubin-src`, running the
v0.30.0 vllm image that bundles the flashinfer cubin dist) — an air-gap workaround for
the runtime `edge.urm.nvidia.com` fetch (documented in
`charts/qwen38-bundled/values.yaml` nodePrep comment).

### 3.8 Auxiliary jobs (glm53)

10 Jobs in `live-cluster/ns-llm-glm53/jobs_batch.yaml`: 4 model-pull jobs
(`glm53-pull-{,flash-}gpu-node-{1,2}`, s5cmd-based, idempotent via a
`.download-complete` marker per node — chart mechanism documented in
`charts/glm53-bundled/README.md`) and 6 live-only 2026-10-12 repair jobs
(`glm53-flash-mtpfix-*` per node, `glm53-flash-bucket-repair`, `glm53-flash-cfg-check`,
`glm53-flash-s3-search{2,3}`) that verify/re-sync the model's `model_mtp.safetensors`
from the S3 bucket (the MTP draft weights were found stale — the trigger for the
in-flight rollout, §7). The pull/repair job pod specs embed the S3 endpoint and
credentials (env vars from `glm53-s3`); those values are dropped in this export
(see `SECURITY_SANITIZATION.md`).

---

## 4. Gateway objects

All in `live-cluster/ns-envoy-ai-gateway-system/` unless noted. Gateway API
implementation: Envoy Gateway v1.9.2 + Envoy AI Gateway (ai-gateway-controller
v1.2.0-patched.1 — patched internal build, pinned per
`gitops/app-of-apps/operators/envoy-ai/values.yaml`).

### 4.1 GatewayClass + Gateway

- **GatewayClass `envoy-ai-gateway`** (`cluster-scoped/gatewayclasses…yaml`):
  controllerName `gateway.envoyproxy.io/gatewayclass-controller`, parametersRef →
  EnvoyProxy `envoy-ai-gateway` (same ns). Argo-tracked (envoy-ai-deploy), sync-wave 1.
- **Gateway `envoy-ai-gateway`** (`gateways_gateway_networking_k8s_io.yaml`), 2 listeners:

| Listener | Port/Protocol | TLS | allowedRoutes | Attached routes |
|---|---|---|---|---|
| `http` | 80 / HTTP | — | `namespaces: All` (required for KServe's model-namespace HTTPRoutes, per chart comment) | 8 |
| `peers` | 8443 / HTTPS | Terminate, cert Secret `llm-peer-server` (fleet CA) | label selector `aigw-ui.io/serving: "true"` | 2 |

  Gateway address = the LoadBalancer service VIP (`envoy-ai-gateway` in
  envoy-gateway-system, externalTrafficPolicy Local; AKO/AVI load-balancer annotations on
  the Service, ingress hostname `<lb-hostname>`, VIP `<gateway-vip>`). An OpenShift Route
  `envoy-ai-gateway` (edge TLS → http-80) additionally exposes it via the cluster's
  router domain.

### 4.2 HTTPRoutes (all, with match conditions and backends)

Model-namespace routes (`httproutes_gateway_networking_k8s_io.yaml` per ns):

| HTTPRoute | Parent | Matches | Backend |
|---|---|---|---|
| `glm53` (llm-glm53) | http listener | header `x-ai-eg-model: glm-5.3` (and OpenAI-body model-name routing via extproc) | InferencePool `glm53-b200-inference-pool` (EPP path) |
| `glm53-anthropic-alias` (llm-glm53) | http | header `x-ai-eg-model: ^claude-.*$` + header `anthropic-version` present | AIServiceBackend `glm53-anthropic` (schema Anthropic) |
| `glm53-b200-kserve-route` (llm-glm53) | http | path prefixes `/llm-glm53/glm53-b200/{v1/completions,v1/chat/completions,v1/responses,v1/messages}` and `/publishers/llm-glm53/models/glm-5.3/...` (+ header `X-Gateway-Model-Name` routing) + catch-all → workload svc | Service `glm53-b200-kserve-workload-svc` (bypasses EPP) |
| `glm53-peer` (llm-glm53) | peers listener | model glm-5.3 on the peer listener | InferencePool (fleet inbound) |
| `glm53-peer-health` (llm-glm53) | peers | GET `/healthz/glm-5.3` | direct-response 200 (health probe for the fleet) |
| `qwen36-judge` (llm-judge) | http | header `x-ai-eg-model: judge` | InferencePool `qwen36-judge-inference-pool` |
| `qwen36-judge-kserve-route` (llm-judge) | http | path `/llm-judge/qwen36-judge/v1/...` + publishers path + catch-all | Service `qwen36-judge-kserve-workload-svc` |
| `qwen38` (llm-qwen38) | http | header `x-ai-eg-model: Qwen3.8-27B-FP8` | InferencePool `qwen38-l4-inference-pool` |
| `qwen38-l4-kserve-route` (llm-qwen38) | http | path `/llm-qwen38/qwen38-l4/v1/...` + publishers path + catch-all | Service `qwen38-l4-kserve-workload-svc` |
| `fleet-glm-5-3` (envoy-ai-gateway-system) | http | header `x-ai-eg-model: glm-5.3` (fleet entry; live-only) | AIServiceBackends `fleet-glm-5-3`, `fleetbe-glm-5-3` |

Each extproc-driven route (from AIGatewayRoute translation) also has a
`ai-eg-host-rewrite-<name>` HTTPRouteFilter (host rewrite to the backend) and
`ai-eg-route-not-found-response-<name>` (direct-response 404 when no model rule matches) —
generated by the ai-gateway controller.

### 4.3 Backends (direct Endpoints, bypassing Services)

| Backend | ns | Endpoints | Used by |
|---|---|---|---|
| `glm53-ranks` | llm-glm53 | 8× FQDN `glm53-b200-ranks-svc.llm-glm53.svc.cluster.local:8000-8007` (one per DP rank) | AIServiceBackend `glm53-anthropic` (native Anthropic path) |
| `qwen36-judge-workload` | llm-judge | 1× FQDN `qwen36-judge-kserve-workload-svc.llm-judge.svc.cluster.local:8000` | AIServiceBackend `qwen36-judge-openai` |
| `qwen38-anthropic-workload` | llm-qwen38 | 1× FQDN `qwen38-l4-kserve-workload-svc.llm-qwen38.svc.cluster.local:8000` | AIServiceBackend `qwen38-anthropic` |
| `fleet-glm-5-3` | envoy-ai-gateway-system | FQDN `peers.llm.<site-domain>:8443` — **self-loop through the Gateway's own peers listener**, zone-locality set, TLS: CA from ConfigMap `llm-peer-ca`, client cert Secret `llm-peer-client`, SNI = peers server name | AIServiceBackends `fleet-glm-5-3`/`fleetbe-glm-5-3` (fleet: local site serves its own model; a remote site's Backend would instead point at that site's peers listener) |

No TLS block on the model-namespace Backends (in-cluster plaintext to the workload svc);
the fleet Backend is the only TLS one.

### 4.4 BackendTrafficPolicy `fleet-glm-5-3` (live-only, aigw-ui)

`backendtrafficpolicies_gateway_envoyproxy_io.yaml`, targetRef the fleet Backend:

| Setting | Value | Effect |
|---|---|---|
| `consistentHash` | headers `x-claude-code-session-id`, `x-openwebui-chat-id`; tableSize 65537 | session affinity: requests carrying a session header pin to the same backend endpoint (rank) |
| `circuitBreaker` | maxRequests 100000, maxConnections 100000, … (all ×100000 s) | effectively disabled breaker headroom |
| health check | active HTTP `/healthz/glm-5.3`, interval 5s, healthy threshold 1 | marks the self-loop backend healthy |
| retry | on `503` + `reset` | retries failed forwards |

### 4.5 ClientTrafficPolicies (chart-managed)

`clienttrafficpolicies_gateway_envoyproxy_io.yaml`, both targetRef the Gateway:

- **`client-buffer-limit`** (target: Gateway): `bufferLimit: 50Mi`; http2
  initialStreamWindowSize 16Mi / initialConnectionWindowSize 24Mi; `idleTimeout: 3600s`
  (long streamed answers); `removeRequestHeaders` **before auth** (anti-spoofing — a
  client must not set the gateway-internal identity/routing headers):
  `x-aigw-client-id`, `x-llm-d-inference-objective`, `x-llm-d-inference-fairness-id`,
  `x-gateway-inference-objective`, `x-gateway-inference-fairness-id`,
  `x-gateway-destination-endpoint`, `x-gateway-destination-endpoint-subset`,
  `x-llm-d-model-name-rewrite`, `x-gateway-model-name-rewrite`, `x-site-pin`.
- **`peers`** (target: peers listener): mutual-TLS client validation against CA ConfigMap
  `llm-peer-ca`; response header `x-llm-served-by: <site>` (site identity on answers);
  `requestID: PreserveOrGenerate` (keeps the entry-site request ID through the fleet hop).

### 4.6 AIGatewayRoute / AIServiceBackend schema translation

- The ai-gateway controller translates each AIGatewayRoute into plain HTTPRoute +
  HTTPRouteFilters (host-rewrite + route-not-found-404) and attaches its ext_proc
  (model-name extraction from the body, token metering, schema translation). Argo CD
  `ignoreDifferences` for the weight/priority/modelsOwnedBy fields the controller
  stamps after apply (documented in `gitops/app-of-apps/operators/glm53/glm53.yaml`).
- **AIServiceBackend.schema** selects the wire protocol the backend speaks:
  `glm53-anthropic`/`qwen38-anthropic` = **Anthropic** (vLLM's native `/v1/messages`),
  `qwen36-judge-openai` = **OpenAI**; the fleet AIServiceBackends = OpenAI. The
  extproc translates Anthropic↔OpenAI when the route schema and backend schema differ
  (the `glm53-anthropic-alias` route lets Claude Code clients send `claude-*` model ids
  and get them rewritten to `glm-5.3`).
- The judge route is the reverse case: OpenAI-schema backend reached from the OpenAI
  surface (no translation).

### 4.7 SecurityPolicies (API-key auth)

| SecurityPolicy | ns | Target | Auth |
|---|---|---|---|
| `glm53-b200-kserve-route-internal` | llm-glm53 | HTTPRoute `glm53-b200-kserve-route` | `apiKeyAuth`: credentialRefs Secret `glm53-internal-key`; extract from header `Authorization`; `sanitize: true` |
| `aigw-ui-api-key-auth` (live-only) | envoy-ai-gateway-system | (fleet route) | API keys from Secret `aigw-ui-api-keys` (aigw-ui-managed key set); accepted via `Authorization` and `x-api-key`; the validated client id is forwarded upstream as `x-aigw-client-id` (used as the QuotaPolicy bucket key, §5) |

### 4.8 EnvoyPatchPolicy `fleet-glm-5-3-retry` (live-only)

JSON patches into the generated xDS route config (`envoypatchpolicies_gateway_envoyproxy_io.yaml`):
`route.route_policy.host_selection_retry_max_attempts: 20` (retry host reselection),
removal of `auto_host_rewrite`, `host_rewrite_literal: peers.llm.<site-domain>` —
together with the BackendTrafficPolicy retry this makes the self-loop fleet forward
reselect hosts and present the right SNI/Host to the peers listener.

### 4.9 EnvoyProxy + data plane + ratelimit

- **EnvoyProxy `envoy-ai-gateway`** (`envoyproxies_gateway_envoyproxy_io.yaml`): envoy
  image `registry-internal/kserve/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c1…`
  (digest-pinned mirror — ImageTagMirrorSet cannot redirect digest refs), 3 replicas
  (site override; chart default 1), PDB minAvailable 1, service type LoadBalancer
  (`externalTrafficPolicy: Local`), resources 100m/256Mi → 1Gi.
- **Data plane**: Deployment
  `envoy-envoy-ai-gateway-system-envoy-ai-gateway-04213612` (Envoy Gateway-generated, in
  envoy-gateway-system) 3/3 ready, pods spread across all 3 nodes (endpointslices), plus
  `shutdown-manager` sidecar (gateway:v1.9.2).
- **ai-gateway-controller** Deployment flags (from
  `deployments_apps.yaml` in ns-envoy-ai-gateway-system):
  `--extProcImage …ai-gateway-extproc:v1.2.0-patched.1`,
  `--endpointPrefixes=openai:,cohere:/cohere,anthropic:/anthropic,typesafe:/typesafe`,
  `--quotaRateLimitServiceAddr=envoy-ai-gateway-ratelimit.envoy-gateway-system`,
  `--quotaRateLimitFailureModeDeny=false` (quota outages fail open),
  `--mcpSessionEncryptionIterations=100000`.
- **Rate-limit service**: Deployment `envoy-ai-gateway-ratelimit`
  (image `registry-internal/kserve/envoyproxy/ratelimit:0482748e`) + Service :8081 (gRPC).
  Backed by an external shared Redis (TLS, credentials in live Secret
  `envoy-ai-quota-redis-client`) — required for QuotaPolicy enforcement (§5).

---

## 5. Quota objects (QuotaPolicy)

Four QuotaPolicies live: `judge` (llm-judge), `qwen3-8-27b-fp8` (llm-qwen38), `glm-5-3` and
`fleetbe-glm-5-3` (envoy-ai-gateway-system). All four are **live-only** (aigw-ui-managed,
§2). Sources: `quotapolicies_aigateway_envoyproxy_io.yaml` in each namespace. They share
one structure:

```yaml
spec:
  targetRefs:            # which AIServiceBackend the quota applies to
    - kind: AIServiceBackend
      name: <name>
  mode: Shared           # bucket budget shared across all clients in the bucket
  serviceQuota:          # whole-service cap
    limit: 4294967295    # max=uint32 (effectively unlimited) per 1 second
    window: 1s
  perModelQuotas:        # one entry per served model name
    - modelName: <model>
      bucketRules:       # per-client buckets
        - clientSelectors:      # regex on the forwarded identity header
            - header: x-aigw-client-id
              match: <regex>
          limit: 500000        # cost units
          window: 1d
      defaultBucket:     # everyone else
        limit: 1
        window: 1d       # deny-by-default
      costExpression:    # CEL-style token cost formula
```

| QuotaPolicy | Targets (AIServiceBackend) | Buckets | Default bucket | Cost formula (input=I, cached=C, output=O) |
|---|---|---|---|---|
| `judge` | `qwen36-judge-openai` | 7 named user buckets (`user-1`…`user-7`, regex on `x-aigw-client-id`), 500k / 1d each | 1 / 1d (deny) | `((C <= I ? I - C : I) * 1200u + C * 120u + O * 4800u) / 1000000u` |
| `qwen3-8-27b-fp8` | `qwen38-anthropic` | same 7 user buckets, 500k / 1d | 1 / 1d (deny) | same rates (1200 / 120 / 4800) |
| `glm-5-3` (fleet) | `fleet-glm-5-3` | 7 user buckets, 1M / 1d | 4294967295 / 1h (unlimited) | fleet rates: uncached ×11600, cached ×1160, output ×46300 |
| `fleetbe-glm-5-3` | `fleetbe-glm-5-3` | identical to `glm-5-3` but **`shadowMode: true` on every bucket** | — | same as `glm-5-3` |

Semantics (from field names + the gateway's quota pipeline):

- **clientSelectors** match the `x-aigw-client-id` header the SecurityPolicy forwards
  after API-key validation (§4.7) — i.e. buckets are per API key, not per IP.
- **costExpression** is a CEL-style arithmetic expression over the request-usage
  metadata the gateway extracts (input/cached-input/output tokens); the cached-input
  term is why the workloads run `--enable-prompt-tokens-details`. Result is in
  cost units (÷1e6), charged against `limit` per `window`.
- **shadowMode** (fleetbe): counts and evaluates but does not deny — the `fleetbe`
  copy is a dry-run twin of the `glm-5-3` policy, targeting the best-effort
  AIServiceBackend (`x-llm-d-inference-objective: best-effort` → InferenceObjective
  `best-effort`, priority -1).
- **serviceQuota** 4294967295/1s = uint32 max per second: no service-level cap in
  practice; enforcement is per-bucket.
- Enforcement path: extproc → ratelimit service (`envoy-ai-gateway-ratelimit`) → shared
  Redis; `--quotaRateLimitFailureModeDeny=false` means quota-infrastructure outages fail
  open.

---

## 6. Cluster-scoped objects

Sources: `live-cluster/cluster-scoped/`.

### GatewayClass

`envoy-ai-gateway` — see §4.1 (`gatewayclasses_gateway_networking_k8s_io.yaml`).

### StorageClasses + PVs (model/cache volumes)

| StorageClass | Provisioner | Reclaim | Binding | Notes |
|---|---|---|---|---|
| `local-static` | `kubernetes.io/no-provisioner` | Retain | WaitForFirstConsumer | glm53 volumes |
| `qwen38-local-static` | `kubernetes.io/no-provisioner` | Retain | WaitForFirstConsumer | qwen38's own class (charts never share an ArgoCD-managed SC) |
| `lvms-vg1` | `topolvm.io` | Delete | WaitForFirstConsumer | params `csi.storage.k8s.io/fstype: xfs`, `topolvm.io/device-class: vg1` |

| PV | SC / size | Local path | Node affinity | Bound to |
|---|---|---|---|---|
| `glm53-models` | local-static / 1200Gi | `/var/mnt/llm/models` | `kubernetes.io/hostname In [gpu-node-1, gpu-node-2]` | PVC `glm53-models` |
| `glm53-cache` | local-static / 300Gi | `/var/mnt/llm/cache` | same two B200 nodes | PVC `glm53-cache` |
| `glm53-cache-l2` | local-static / 2500Gi | `/var/mnt/llm/lmcache-l2` | same two B200 nodes | PVC `glm53-cache-l2` |
| `qwen38-models` | qwen38-local-static / 200Gi | `/var/mnt/llm/models` | util-node-1 | PVC `qwen38-models` |
| `qwen38-cache` | qwen38-local-static / 150Gi | `/var/mnt/llm/cache` | util-node-1 | PVC `qwen38-cache` |
| `qwen38-cache-l2` | qwen38-local-static / 1000Gi | `/var/mnt/llm/lmcache-l2` | util-node-1 | PVC `qwen38-cache-l2` |
| `pvc-7cbbc0cf-…` | lvms-vg1 / 1Ti | — | `topology.topolvm.io/node In [gpu-node-1]` | PVC `glm53-model` (live-only, §7) |
| `pvc-31f3252f-…` | lvms-vg1 / 1Gi | — | `topology.topolvm.io/node In [gpu-node-1]` | (small utility claim) |

Design (from `charts/glm53-bundled/README.md`): one local PV per volume whose
nodeAffinity lists ALL target nodes at the SAME host path, so a single Deployment at
replicas > 1 mounts each pod's own node's copy through one claim name; `volumeName`-pinned,
bound immediately, never pruned (Retain). The node-prep DaemonSet (§3.7) guarantees the
path exists on every node.

### RuntimeClasses

| RuntimeClass | Handler | Node selector |
|---|---|---|
| `nvidia` / `nvidia-cdi` / `nvidia-legacy` | nvidia / nvidia-cdi / nvidia-legacy | — |
| `performance-gpu-hpc-performanceprofile-extras-b200` | high-performance | `node-role.kubernetes.io/b200: ""` |
| `performance-gpu-hpc-performanceprofile-extras-l4` | high-performance | `node-role.kubernetes.io/l4: ""` |

The performance classes select the CPU-isolated, hugepages-enabled node configuration
(see Tuned below); glm53 uses the b200 class, qwen38 the l4 class (§3).

### PerformanceProfile / CPU isolation / hugepages

`cluster-scoped/performanceprofiles.yaml` in the export is **empty** — PerformanceProfile
CRs were not captured. The isolation they produced is directly observable on the nodes
(`nodes.yaml`, `tuned.openshift.io/bootcmdline` annotation) and in the Tuned profiles:

| Node | isolcpus / nohz_full | hugepages-1Gi (capacity=allocatable) | systemd housekeeping CPUs |
|---|---|---|---|
| gpu-node-1, gpu-node-2 | `16-127,144-255` (224 of 256 CPUs isolated) | 64Gi | 0-15,128-143 |
| util-node-1 | `8-71,80-143` (128 of 144 CPUs isolated) | 64Gi | 0-7,72-79 |

Additional boot cmdline: `intel_iommu=on iommu=pt`, `tsc=reliable`, `nosoftlockup`,
`nmi_watchdog=0`, `rcu_nocbs` matching the isolated ranges (kernel
`5.14.0-687.31.1.el9_8`, OCP 4.22, RHEL 9.8).

### Tuned profiles (GPU nodes)

`cluster-scoped/tuned-all.yaml`:

| Tuned | Applied to (machineConfigLabels / recommend) | Key settings |
|---|---|---|
| `gpu-hpc-tuned-extras-b200-*` / `gpu-hpc-tuned-extras-l4-*` | role `b200` / `l4` (priority 19) | include the matching performance profile; sysctls: `vm.swappiness=0`, `vm.zone_reclaim_mode=0`, `vm.max_map_count=1048576`, `vm.min_free_kbytes=4194304`, `net.core.{r,w}mem_max=536870912`, `net.ipv4.tcp_rmem/wmem` up to 256MiB, `fs.aio-max-nr=1048576`, ARP filtering (`arp_ignore=1`, `arp_announce=2`, `arp_filter=1`, `rp_filter=2`), `transparent_hugepages=madvise` |
| `openshift-node-performance-gpu-hpc-performanceprofile-extras-{b200,l4}-*` | role `b200` / `l4` (priority 20) | includes `cpu-partitioning` (+ vendor arch profile chain) — the tuned side of the PerformanceProfile CPU isolation |
| `default` | all | stock openshift-node / control-plane split |

### Nodes summary

| Node (placeholder) | Hardware | GPUs | Capacity | Allocatable | Taints | Role labels |
|---|---|---|---|---|---|---|
| `gpu-node-1` | Dell PowerEdge XE9780 | 8× NVIDIA B200 (183Gi each, compute cap 10.0) | 256 CPU / ~2 TiB / 64Gi hugepages-1Gi | 224 CPU / ~1.9 TiB | none | `b200`, `worker` |
| `gpu-node-2` | Dell PowerEdge XE9780 | 8× NVIDIA B200 | same | same | none | `b200`, `worker` |
| `util-node-1` | Dell PowerEdge R760xa | 8× NVIDIA L4 (23Gi each, Ada) | 144 CPU / ~504 GiB / 64Gi hugepages-1Gi | 128 CPU / ~438 GiB | none | `l4`, `worker` |

All three: HyperShift-managed (`hypershift.openshift.io/managed: "true"`), OCP 4.22,
kernel 5.14.0-687.31.1.el9_8, NVIDIA driver 580.126.20 (CUDA runtime 13.0), RDMA-capable
NICs present (RoCE for NCCL is deliberately disabled in-workload: `NCCL_IB_DISABLE=1`),
GPU operator labels (device-plugin, DCGM, GFD deployed). util-node-1 additionally hosts
the non-Gateway control-plane pods of the stack (ai-gateway-controller, envoy-gateway,
ratelimit, kserve/lmcache controllers — see endpointslices) and the L4 models.

---

## 7. Current live configuration deltas (live state vs rendered chart defaults)

Baseline = the charts and values shipped in this archive (`charts/…/values.yaml` and
`gitops/app-of-apps/…`). Everything below was read from the live exports.

### 7.1 glm53 workload: live vLLM args vs `charts/glm53-bundled/values.yaml`

The live LLMInferenceService (generation 50) renders a later, tuned configuration than
the chart copy in this archive:

| Setting | Chart default (`llmisvc.*`) | Live | Note |
|---|---|---|---|
| `--kv-cache-dtype` | `fp8_e4m3` | `fp8` | fp8 = auto (e4m3/e5m2 by model) |
| `--gpu-memory-utilization` | `0.90` ("KEEP AT 0.90" comment) | `0.85` | more headroom after LMCache cutover |
| `--max-num-seqs` | `64` (per DP rank → 512/node) | `512` | expressed per-pod in live args |
| `--max-num-batched-tokens` | `16384` (comment: "Try 32768 next") | `32768` | the suggested bump is live |
| `--speculative-config.num_speculative_tokens` | `5` | `3` | reduced MTP draft depth |
| `--reasoning-parser` | `glm47` | `glm45` | |
| `--load-format=auto`, `--enable-chunked-prefill`, `--enable-prompt-tokens-details`, `--enable-force-include-usage` | absent from chart args | present | preset-contributed + billing flags ("vLLM billing flags, 2026-10-12" per `gitops/app-of-apps/operators/glm53/glm53.yaml`) |
| `--kv-transfer-config` | not in args (chart uses `kvCacheOffloading.cpu: 64Gi` → OffloadingConnector) | explicit `LMCacheMPConnector` → lmcache engine | LMCache cutover; the explicit arg overrides the chart's CPU-offload spec |
| image | `vllm-openai:v0.30.0` (tag) | `vllm-openai@sha256:464346c4…` (digest, LMCache-enabled build) | digest-pinned internal build |
| EPP `prefix-cache-scorer` weight | `1` | `3` | rebalanced scheduler profile |
| model subPath / S3 source | `GLM-5.3` from `s3://llms/zai-org/GLM-5.3` | `GLM-5.3-Flash-NVFP4` from `s3://llms/…/GLM-5.3-Flash-NVFP4` | Flash NVFP4 quantization of GLM-5.3 |

### 7.2 Structural deltas (live objects with no counterpart in the exported chart copy)

The **deployed** glm53 chart (Argo app `glm53-deploy`, branch `bundled`, per
`gitops/app-of-apps/operators/glm53/glm53.yaml`) is a newer revision than the
`charts/glm53-bundled/` snapshot in this archive. Live Argo-tracked objects whose
templates are absent from the exported chart copy:

- **LMCacheEngine `glm53-cache`** + PVC `glm53-cache-l2` (2500Gi) + DaemonSet
  `glm53-cache` + `glm53-cache-connection` ConfigMap + ServiceMonitor/PrometheusRule
  (created 2026-10-06/07; `charts/glm53-bundled/templates/` has no `lmcache-engine.yaml`,
  unlike `charts/qwen38-bundled/templates/lmcache-engine.yaml`).
- **AIGatewayRoute `glm53-peer`** + HTTPRoutes `glm53-peer`, `glm53-peer-health`
  (fleet peer-serving attach; no peer template in the exported chart — the newer
  generic chart `charts/llm-model/templates/peer.yaml` shows where the feature landed).

Same pattern for the gateway: the live **peers listener** on Gateway `envoy-ai-gateway`,
ClientTrafficPolicy `peers`, Certificates `llm-peer-{client,server}`, ConfigMap
`llm-peer-ca` are all Argo/Helm-managed (tracking-id `envoy-ai-deploy`, created
2026-10-11 22:19Z), but the exported chart default is `gateway.peers.enabled: false` and
**no values layer in the exported gitops tree enables it** — the enabling overlay was not
captured in this archive.

### 7.3 Site-level overrides that ARE in the archive (live matches, listed for completeness)

- `gitops/.../cluster-llm-prep/envoy-ai/values.yaml`: data-plane replicas **3** (chart
  default 1), LB Service `externalTrafficPolicy: Local`, ratelimit Redis via
  `existingSecret: envoy-ai-quota-redis-client` with `tls: true` — all confirmed live.
- `gitops/app-of-apps/operators/envoy-ai/values.yaml`: patched controller/extproc images
  `v1.2.0-patched.1` — confirmed live.
- `charts/qwen38-bundled/values.yaml` and `charts/qwen36-judge/values.yaml`: live
  workloads match the chart values (TP4/DP1, mtp k=2, judge args, images).

### 7.4 Operational state at export time (not config drift, but visible in live state)

- **glm53 mid-rollout**: LLMInferenceService generation 50, workload Deployment
  revision 32/generation 51; at export both vLLM pods were unavailable
  (`MinimumReplicasUnavailable` — endpointslices for the workload show
  `ready: false` on both B200 nodes). Trigger: the 2026-10-12 MTP repair jobs (§3.8)
  re-syncing `model_mtp.safetensors`, followed by a restart of the workload.
- The EPP pods, LMCache engines, judge and qwen38 workloads, all three data-plane Envoy
  replicas and all controllers were ready at export (endpointslices §ns-*).
- The chart's "known cosmetic issue" (InferencePool status conditions never written by
  anything, so the isvc shows `InferencePoolReady=False` while the data plane works)
  is documented in `charts/glm53-bundled/README.md`.
- The glm53 LLMInferenceService was kubectl-applied once server-side (SSA
  `ServerSideApply=true` sync option + the `resourceVersion: Invalid value: 0` note in
  `gitops/app-of-apps/operators/glm53/glm53.yaml`) — the app yaml's comments explain why.

### 7.5 Live-only additions not in any chart (already listed §2, with live detail)

- Fleet objects (`fleet-glm-5-3*`, aigw-ui): BackendTrafficPolicy hash keys
  (`x-claude-code-session-id`, `x-openwebui-chat-id`), EnvoyPatchPolicy retry tuning.
- QuotaPolicies (4): see §5.
- PVC `glm53-model` (1Ti lvms-vg1, gpu-node-1): a pre-charter manual claim; the chart's
  own `glm53-models` (1200Gi local-static, both nodes) is the one the workload mounts —
  the 1Ti claim is unused by the current workload spec (mounted nowhere in
  `deployments_apps.yaml`).
- ConfigMap `glm53-100k-script` + the six `glm53-flash-*` repair jobs (2026-10-12).

---

*End of LIVE_STATE.md. Companion docs: `README.md` (archive map),
`SECURITY_SANITIZATION.md` (sanitization methodology + placeholder conventions).*
