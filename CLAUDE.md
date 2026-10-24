# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **sanitized, point-in-time export** (2026-10-12) of an LLM serving stack on a HyperShift-hosted OpenShift 4.22 cluster (`cluster-llm-prep`): GLM-5.3 on two B200 nodes, Qwen3.8 and a Qwen3.6 "judge" on one L4 node, served by KServe `LLMInferenceService` + llm-d EPP, fronted by Envoy Gateway + Envoy AI Gateway, with LMCache, per-client token quotas and a cross-site "fleet" path.

It is a snapshot kept in git, not the source of truth. The real sources are per-chart git repos, the `popai` values repo, and `argocd-day2-platform`. Editing files here deploys nothing, **except on the lab**: since 2026-10-24 the lab's Argo CD (on the aigw-ui hub cluster) reads `main` through `gitops/aigw-ui/bootstrap` — `charts/model-deployer`, `gitops/app-of-apps/operators/<model>/` and `gitops/app-of-apps/sites/site-lab/**` are live there, and the aigw-ui hub commits to `gitops/app-of-apps` (author `aigw-ui`, messages `aigw-ui: …`). Do not rewrite those commits or hand-edit a file the hub is changing; a hand edit is fine (the hub reads files back).

## Hard rules

- **No cluster operations.** `kubectl`, `oc` and `argocd` are installed and may point at a real cluster. Never run them, or `helm install/upgrade`, unless the user explicitly asks. The only verification loop is `helm lint` and `helm template` to stdout.
- **Keep it sanitized.** Never replace a placeholder with a real hostname, IP, registry, node, user or key, and never try to infer one. New content uses the same placeholders.
- **Do not "fix" sanitizer artifacts.** `REDACTED`, `REDACTED-B64`, `REDACTED-ENV`, `REDACTED-HEX` and `REDACTED-PEM-BLOCK` appear inside templates and values (for example `type: REDACTED`, `kind: REDACTED`). They are not bugs to guess at.
- **Do not run `helm dependency build/update`** (needs the network and rewrites files).

## What to trust

Precedence when sources disagree: `live-cluster/` YAML > `gitops/app-of-apps/` > `charts/` > `docs/`.

- **`docs/` is unreliable.** `ARCHITECTURE.md`, `LIVE_STATE.md`, `GITOPS.md` and `CHARTS.md` contradict each other and the files (route tables, quota schema and limits, sync options, API versions, layer order). Verify any doc claim against YAML before repeating it.
- **Doc path aliases:** `cluster/…` means `live-cluster/…`; `argocd/…` means `gitops/app-of-apps/…`.
- **Exported charts are not the deployed revisions** for glm53, envoy-ai and envoy-gateway. `charts/glm53-bundled` is the `main` branch; live runs branch `bundled` (LMCache, peer route, different vLLM args). Its "KEEP AT 0.90" comment is superseded. Do not copy values from it as if live.
- **`gitops/platform-repo/` is an older checkout** of the same values repo. Use `gitops/app-of-apps/`.
- **Chart READMEs and comments are stale in places** (qwen38 still says TP2xDP3 and chunk 1568; values are TP4/DP1 and 1600).
- **Not in this export:** the kserve and lmcache charts (the root README wrongly lists them under `charts/platform/`), the `glm53-anthropic-alias` chart, the ApplicationSet chain and `deploy` chart, the values that enable the live `peers` listener, PerformanceProfiles (file is empty), and every `scripts/` directory or `_validate.tpl` under `generic-model` that the docs cite.

## Reading `live-cluster/`

- Files are `kind: List` dumps named `<plural>_<api group with underscores>.yaml`. `status` is kept; `managedFields` is stripped.
- Placeholders actually used (the docs describe different ones): every hostname is `host.example.internal` (S3, Redis, peers SNI, Route host are all the same string), both B200 nodes are `gpu-node-x`, the L4 node is `ocp-util-node-1`, IPs are `192.0.2.N`, images are `registry-internal/…`. Two references to the same placeholder do not mean the same host. Sanitization also produces duplicate object names.
- `status` is a snapshot taken mid-rollout (glm53 was 0/2 ready). Do not read it as steady state.
- Not configuration: `pods_metrics_*`, ReplicaSets, ControllerRevisions, ClusterServiceVersions, Leases, `nodes.yaml` `status.images`, and KServe preset default images (`ghcr.io/…`).
- `last-applied-configuration: REDACTED` appears on Argo-managed objects too; it does not mean hand-applied.
- Of the two InferencePool API groups, only `inference.networking.k8s.io/v1` is wired. The `x-k8s.io` twin is referenced by nothing.

### Who owns an object

| Marker | Owner |
|---|---|
| `argocd.argoproj.io/tracking-id: gitops-popai_popai-cluster-llm-prep-<app>:…` + `helm.sh/chart` | An Argo CD app / Helm chart |
| `ownerReferences` | A controller (KServe, AI Gateway, lmcache-operator, Envoy Gateway). Generated HTTPRoutes copy their parent's tracking-id but are controller-owned |
| `app.kubernetes.io/managed-by: aigw-ui` | aigw-ui (see below); never in any chart |
| none | Applied by hand (S3 secrets, `glm53-internal-key`, repair Jobs, PVC `glm53-model`) |

## Request path

The bullets below describe the `live-cluster/` snapshot. **The three model charts and the `envoy-ai` image tags describe a target that is not deployed**: every request takes aigw-ui's entry route, and the charts put nothing on the client listener (`docs/ENTRY_ROUTE_MIGRATION.md`). For routing, the charts and the snapshot disagree on purpose.

Client → OpenShift Route or LoadBalancer → Gateway `envoy-ai-gateway` (namespace `envoy-ai-gateway-system`; data plane and ratelimit run in `envoy-gateway-system`).

- Listener `http` :80 accepts routes from all namespaces. SecurityPolicy `aigw-ui-api-key-auth` targets the whole listener, takes the key from `Authorization` or `x-api-key`, and forwards identity as `x-aigw-client-id`.
- Listener `peers` :8443 is mTLS (Secret `llm-peer-server`) and only accepts routes from namespaces labelled `aigw-ui.io/serving: "true"`.
- Routing is by header `x-ai-eg-model`, which the extproc derives from the request body.
- OpenAI traffic for `glm-5.3`: AIGatewayRoute `fleet-glm-5-3` → Backend that hairpins to this cluster's own `peers` listener → `glm53-peer` → InferencePool → EPP → one of rank ports 8000-8007.
- Anthropic traffic (`^claude-.*$`, or `glm-5.3` with an `anthropic-version` header) goes to a schema-Anthropic AIServiceBackend and bypasses the EPP.
- Quotas: QuotaPolicy (v1alpha1) attaches only to an AIServiceBackend, buckets match `x-aigw-client-id`, counters live in an external Redis, and enforcement fails open.

## aigw-ui (companion repo `git@github.com:roiblum1/aigw-ui.git`)

- From aigw-ui 0.35.0 its Deployments page reads and writes `gitops/app-of-apps` in the platform's layout: a model is an operator whose values have `model.name`; it writes a cluster's `<op>/values.yaml` as what differs from the layers below (patched, comments kept), recipes, and new operators (copied app config, object names renamed). Keep that layout and the layer order of `gitops/aigw-ui/bootstrap/applicationset.yaml` (= the platform's), and keep model charts' values under `model.name`, `namespace` (= projectNamespace), `llmisvc.args`/`extraArgs` (plain tokens or `--opt='value'`).

A Go hub service (React UI, Postgres) that writes gateway objects directly to clusters with stored kubeconfigs, outside Helm and Argo CD.

- It owns everything labelled `app.kubernetes.io/managed-by: aigw-ui`: `fleet-<slug>` (AIGatewayRoute, AIServiceBackend, Backend, BackendTrafficPolicy), `fleet-<slug>-retry` (EnvoyPatchPolicy), `fleetbe-<slug>`, QuotaPolicies, InferenceObjective `best-effort`, Secret `aigw-ui-api-keys`, SecurityPolicy `aigw-ui-api-key-auth`.
- **Never template, hand-edit or GitOps-manage those objects, and never put that label on a chart object.** The hub force-applies every 5 minutes and prunes by label.
- It also stamps annotation `gateway.envoyproxy.io/aigw-ui-quota-revision` on chart-owned AIGatewayRoutes. Charts must not strip it.
- **Names are quota counter keys.** Renaming the gateway namespace, an AIServiceBackend or a model silently splits or resets budgets.
- Charts must provide what it assumes: both listeners, ConfigMap `llm-peer-ca`, Secret `llm-peer-client`, a peer-listener route serving the model and answering `/healthz/<model>`, `enableEnvoyPatchPolicy: true`, and the ClientTrafficPolicy header strip list.
- In that repo: `make test`; single test `go test ./internal/render/ -run <Name> -count=1 -v`. CI gates on `gofmt`, `go vet`, `hack/check-duplication.sh`, `hack/check-chart.sh` and `hack/check-release-note.sh` (chart `version` = `appVersion`, with a matching `docs/release-notes/v<version>.md` listed in its README). Commit subjects are plain outcome sentences, releases prefixed `0.12.1: …`. `hack/deploy-hub.sh` and `hack/seed-demo.py` touch live systems; do not run them.

## GitOps (`gitops/app-of-apps/`)

- It is a values repo only. `operators/<op>/<op>.yaml` is deploy config (`repourl`, `targetRevision`, `projectNamespace`, `syncPolicy`, `ignoreDifferences`) consumed by an external generator; there is no `path` key and no Application YAML.
- **A directory is the registration:** an app is enabled on a cluster when `sites/<site>/<env>/mces/<mce>/<cluster>/<op>/` exists, even with an empty `values.yaml`.
- Layering, last wins: chart defaults → `operators/<op>/values.yaml` → … → `sites/…/<cluster>/<op>/values.yaml`. Only those two repo layers exist here. Follow `gitops/app-of-apps/README.md` for the full order, not `docs/GITOPS.md`.
- **Lists replace, maps merge.** Overriding `llmisvc.args`, `catalogSources`, `nodeGroups` or `nvidiaDrivers.drivers` means restating the whole list.
- `targetRevision` values are branch names, so a chart-repo push changes desired state.
- Where a change goes: one cluster → `sites/…/<cluster>/<op>/values.yaml`; all clusters → `operators/<op>/values.yaml`; chart revision → `operators/<op>/<op>.yaml` (or the same file under the cluster directory, as `lws` does).
- Keep `ServerSideApply=true` on glm53, qwen36-judge and lmcache, and `RespectIgnoreDifferences=true` on qwen38. `ignoreDifferences` jsonPointers are case-sensitive.
- Sync mode (manual or automated) is not determinable from these files.

## Charts

```bash
helm lint charts/<chart>
helm template x charts/glm53-bundled            # also qwen38-bundled, qwen36-judge, platform/*
helm template x charts/generic-model -f charts/generic-model/examples/<model>.values.yaml
helm template x charts/llm-model -n ns --set internalKey.value=x
helm template x charts/platform/<c> -f gitops/app-of-apps/operators/<c>/values.yaml -f <site values>
```

- `charts/envoy-gateway` and `charts/envoy-ai-gateway` **do not render as checked in**: their dependencies were extracted to `charts/upstream-subcharts/` instead of each wrapper's `charts/`. To render, copy the wrapper to a scratch directory and place the vendored chart at `<copy>/charts/gateway-helm` or `<copy>/charts/ai-gateway-helm`.
- Monitoring subcharts render standalone only with `--set global.clusterName=x --set global.baseDomain=y`.
- Model and platform charts have no tests or CI; platform charts have no `fail` guards, so bad values render silently or die with nil-pointer errors.
- **`model-deployer`** is the one chart for every model (generic-model's stack + the fleet side, nothing on the client listener). `operators/{glm53,qwen38,qwen36-judge,qwen-tiny}/<op>.yaml` point at it; a model's recipe is `operators/<op>/values.yaml`, a cluster's shape its `sites/…/<cluster>/<op>/values.yaml` (glm53's B200 shape is cluster-llm-prep's). `glm53-bundled`, `qwen38-bundled`, `qwen36-judge`, `generic-model`, `llm-model` are kept for reference. Render: `helm template x charts/model-deployer --kube-version 1.32.0 -f gitops/app-of-apps/operators/<op>/values.yaml -f <cluster layer>`; parity with the old charts is in its README.
- Templates are copy-pasted between sibling model charts (`pull-jobs`, `scc`, `lmcache-engine`, `node-prep`, `local-storage`) and between platform charts (`subscription`, `operatorgroup`, `namespace`). Mirror a fix across them.
- Platform charts follow Namespace (wave 1) → OperatorGroup (2) → Subscription (3) → CR (4+), ordered only by Argo sync-waves. `charts/platform/lvms/CLAUDE.md` exists; its override path and catalog source name predate this layout.

### Invariants from chart comments

- Model charts serve the model on the peer listener only (`templates/peer.yaml`). Keep `aigatewayRoute.enabled`, the direct backend (`anthropicBackend` / `openaiBackend`) and `claudeAlias.enabled` off, and `gateway.aiGateway.kserveRouteListener` at `peers`: each of them puts a way to the model on the client listener that skips the entry route. The peer route's match must stay `Exact`, or aigw-ui does not find the model.
- `llmisvc.keepAliveSeconds` (75) restarts the model pods when it changes. With vLLM's default of 5 a health check meets closing connections, and one 503 on a health check takes the entry route's only endpoint out.
- vLLM args must be single tokens in dot-notation. Do not add `--kv-transfer-config` to values; the template appends it when `lmcache.enabled`.
- The vLLM image and the LMCache engine image must be the same build. qwen38 `nodePrep.image` stays `v0.30.0` (it donates the flashinfer cubins for the air-gap).
- LMCache `chunkSize` is tied to the model and TP shape (256 for glm53, 1600 for qwen38 at TP4). A wrong value silently disables caching, and changing it invalidates the L2 cache.
- `maxSurge: 0` on GPU workloads: there are no free GPUs for a surge pod.
- Pull Jobs are immutable; a spec change needs the Job deleted first.
- Judge: leave `runtimeClassName` unset, no `--tensor-parallel-size` in args, no `scaling` block without KEDA/WVA.
- Envoy Gateway: `envoy-gateway.crds.enabled` must stay false (it would overwrite cluster-owned Gateway API CRDs). Use either full mirror image references or `imageRegistry`, never both.
- AI Gateway: controller and extproc images must come from the same build. The ClientTrafficPolicy header strip list, the peers `allowedNamespaceLabels` and `sectionName` on peer routes are marked DO NOT REMOVE.
- `platform/lvms` defaults to `forceWipeDevicesAndDestroyAllData: true`.
- Gitops Subscriptions reference catalog `generic-cs`, which nothing in this export creates.
