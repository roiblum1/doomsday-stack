# generic-model chart

ONE Helm chart for every per-model LLM serving deployment on the POPAI
clusters. It supersedes the three per-model charts (`glm53-chart`,
`qwen38-chart`, `qwen36-judge-chart`): a new model is a **values file**,
not a new chart.

What it deploys (each piece gated on values):

- `Namespace` (+ `openshift.io/cluster-monitoring` label when the LMCache
  ServiceMonitor is on)
- `LLMInferenceService` (KServe `serving.kserve.io/v1alpha2`) behind the
  llm-d router (EPP + InferencePool) — any parallel shape: DP/EP
  multi-port external LB, TP, WVA/KEDA autoscaling; model from a
  pre-pulled PVC (`pvc://claim/subPath`) or straight from S3
  (`storage-initializer`)
- `AIGatewayRoute` on the shared Envoy AI Gateway (model-header rules)
  + direct `AIServiceBackend`/`Backend` quota path (Anthropic or OpenAI
  schema; `workload-svc` or DP-rank-ports styles)
- node prep DaemonSet (LVM LVs + VG creation from blank disks + flashinfer
  cubin seeding), static local PVs/PVCs, per-node model pull Jobs
- LMCache engine CR (RAM L1 + disk L2, ServiceAccount/SCC binding,
  monitoring RBAC, PrometheusRule)
- optional AIPerf benchmark Job, optional S3 credentials Secret (pull-job
  or kserve shape)

The three shipped example values files reproduce the existing per-model
deployments **byte-identically** (see "Verification" below):

- `examples/glm53.values.yaml` — GLM-5.3, 2x B200, DP8xEP8, LMCache,
  ranks-style Anthropic direct backend, aiperf (off)
- `examples/qwen38.values.yaml` — Qwen3.8-27B-FP8, 1x L4, TP4, LMCache,
  VG-from-blank-disk, workload-svc Anthropic direct backend
- `examples/qwen36-judge.values.yaml` — Qwen3.6 judge, 1x L4, TP2,
  S3-uri + storage-initializer, OpenAI direct backend, no LMCache

## Adding a new model

1. Copy the example closest to your shape:
   `cp examples/qwen38.values.yaml /path/to/<model>.values.yaml`
2. Edit the values — at minimum:
   - `namespace`, `nameOverride` (the fullname prefix for generated names)
   - `nodes.gpuProduct` (+ `nodes.hostnames` if using local storage)
   - `model.name` (what clients send as `"model"`), `model.subPath` +
     `model.s3.path` (PVC shape) or `model.uri` (s3:// shape)
   - `scc.name`, `llmisvc.name`, `aigatewayRoute.name`, PVC names — pick
     names that do not collide with other models' objects (the SCC and
     StorageClass are cluster-scoped; StorageClass defaults to
     `<fullname>-local-static`)
   - `images.vllm` (+ `lmcache.image.*` in lockstep when using LMCache)
   - `llmisvc.args` / `env` / `resources` / `probes` (port + paths) /
     `parallelism` or DP flags, `llmisvc.scheduler` (EPP profile) when
     the default scorers misread multi-rank `/metrics`
   - `lmcache.server.chunkSize` + `chunkSizeModulus` (the render FAILS if
     chunkSize is not a multiple of the modulus — it is model/arch
     specific), `l1.sizeGB`, `l2.maxCapacityGB` (< `storage.l2.pvSize`)
   - `directBackend` (`schema`, `style`, names) + `aigatewayRoute`
     (`requestTimeout`, `claudeAlias` for Anthropic schemas only)
3. Render and eyeball:
   `helm template <model> . -n <ns> --kube-version 1.32.0 -f <model>.values.yaml`
   (the `--kube-version` flag is required — helm otherwise reads the
   v1.28 kubeconfig and fails the chart's `>=1.29` gate)
4. `helm lint . -f <model>.values.yaml` must pass.
5. Argo CD Application pointing at this repo with the per-model values
   file (source.targetRevision `main`, helm.valueFiles
   `["<model>.values.yaml"]` — or host the values file in your own repo
   and reference it as an extra values file). Keep one app per model, as
   today.

## Migration from the per-model charts

| old key (glm53/qwen38/qwen36-judge chart) | new key (generic-model) |
|---|---|
| `anthropicBackend.enabled` | `directBackend.enabled` |
| `anthropicBackend.name` (AIServiceBackend) | `directBackend.name` |
| `anthropicBackend.backendName` | `directBackend.backendName` |
| `anthropicBackend.ranksServiceName` (glm53) | `directBackend.ranksService.name` (+ `firstPort`, `portCount`; `style: ranks`) |
| — (single-endpoint anthropic backends) | `directBackend.style: workload-svc` |
| `openaiBackend.*` (qwen36-judge) | `directBackend.*` with `schema: OpenAI`, `style: workload-svc` |
| (rule name `anthropic-native`/`openai-direct`) | `directBackend.ruleName` — set it for render parity, default `direct-native` |
| `model.subPath` present | same (`model.uri` derives `pvc://<models.pvcName>/<subPath>`) |
| `model.uri` s3:// (judge) | same, and leave `model.subPath` unset |
| `llmisvc.probes` port/path hardcoded per chart | `llmisvc.probes.port` + per-probe `.path` |
| `llmisvc.scaling` (judge) | same; `scaling.enabled: true` renders the block, else `replicas` |
| `llmisvc.initContainers` list (judge) | `llmisvc.storageInitializer.enabled: true` (image: `images.storageInitializer`) |
| `lmcache.server.chunkSize` guard (hardcoded modulus) | `lmcache.server.chunkSizeModulus` (per-model; 0 disables) |
| `s3` keys only used by pull jobs | `s3.shape: pull-job` (default) or `s3.shape: kserve` (judge: AWS_* data keys + serving.kserve.io annotations) |
| `storage.className` | same (default `<fullname>-local-static`) |
| `aigatewayRoute.openaiModel` (glm53 set it) | optional — default derives `publishers/<ns>/models/<model.name>` |

The examples set object names (llmisvc, SCC, PVCs, backends, routes)
exactly to today's values, so an Argo app can switch its chart source to
this repo with the example values and reconcile to the same objects.

### Pull-Job immutable-spec caveat (read before migrating)

The per-node model pull Jobs (`<fullname>-pull-<node>`) have immutable
specs (`batch/v1` Job template). Switching the Argo app to the new chart
renders the same Job objects, but ANY spec change (e.g. resources) would
make Argo unable to apply them. The qwen38 app already carries the fix;
for glm53/qwen36-judge-style apps add to the Application spec BEFORE
migrating:

```yaml
spec:
  syncOptions:
    - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: batch
      kind: Job
      jsonPointers:
        - /spec/template/metadata/labels
```

(or delete the completed pull Jobs out-of-band once and let the new chart
recreate them — the `.download-complete` marker makes re-runs no-ops).

### Known intentional diffs vs the old charts' renders

- `helm.sh/chart: generic-model-0.1.0` label (chart renamed) on every
  object; `app.kubernetes.io/name` stays the fullname (nameOverride), so
  selectors are unaffected.
- `# Source:` comments point at `generic-model/templates/*`.
- glm53 only: the LMCache engine CR now renders `server.chunkSize: 256`
  explicitly (the qwen38 chart already did; the glm53 chart relied on the
  CRD default, which is 256 — no semantic change, keeps the modulus
  guard honest).
- Comment text inside templates/nodes-prep scripts differs (merged
  wording). Whitespace inside the node-prep bash script (one double blank
  line collapsed).
- PrometheusRule alerting group name is now derived:
  `<fullname>-lmcache.rules`. For glm53/qwen38 this is IDENTICAL to today
  (`glm53-lmcache.rules`, `qwen38-lmcache.rules`); the judge chart has no
  PrometheusRule. For any FUTURE model whose old chart hardcoded a
  different group name, migrating renames the group once (alert history
  resets), then it is stable.
- The judge's namespace monitoring label stays OFF (it never had one):
  the label renders only when the LMCache ServiceMonitor is enabled.

### Where the judge's out-of-band artifacts live

The qwen36-judge chart carried `hook/` (judge.py + judge.json, the Claude
Code PreToolUse hook) and `docs/RECIPE.md`. They are CLIENT-side /
runbook artifacts, not chart deliverables, and stay out of this chart:
see the `qwen36-judge-chart` repo (hook/) and the team brain for the
recipe. `NOTES.txt` here covers bring-up and smoke tests generically.

## Verification (render-diff oracle)

For each of the three models, the old chart's render and this chart's
render with the example values were diffed
(`helm template <model> <chart> -n <ns> --kube-version 1.32.0`):

| model | old objects | new objects | substantive diff |
|---|---|---|---|
| glm53 | 29 | 29 | `server.chunkSize: 256` added (documented above) |
| qwen38 | 27 | 27 | none |
| qwen36-judge | 9 | 9 | none |

Everything else differs only in `helm.sh/chart` labels, `# Source:`
comments and template comment text. `helm lint` passes with all three
example values files; rendering with bare defaults fails on the
required-field guards (namespace, model.name, scc.name, llmisvc.name,
aigatewayRoute.name, images.vllm, and the directBackend/lmcache/
claudeAlias-schema/chunkSize-modulus guards).

## Values

See `values.yaml` (commented defaults) and the three examples. Required
fields per deployment: `namespace`, `model.name`, `scc.name`,
`llmisvc.name`, `aigatewayRoute.name` (when enabled), `images.vllm`,
plus `directBackend.name`/`backendName` (when enabled) and
`lmcache.name` (when enabled).
