# model-deployer

One model on one serving site of an aigw-ui fleet. A deployment is a values
file. aigw-ui's Deployments page writes those files to
`gitops/aigw-ui/deployments/<cluster>/<name>.yaml`, and Argo CD's
ApplicationSet `aigw-ui-models` deploys each one with this chart
(`gitops/aigw-ui/bootstrap/`).

It takes from the charts before it:

| From | What |
|---|---|
| `glm53-bundled`, `qwen38-bundled`, `generic-model` | The GPU shapes: tensor parallel (`serving.tensorParallel`), data parallel with one port per rank (`serving.dataParallel.ranks`: the InferencePool's ports, the supervisor probes), GPUs and GPU product, runtime class, no surge pod on GPUs, `/dev/shm`, KV-cache offloading, a scheduler config of a newer endpoint picker (`scheduler.config`), vLLM's keep-alive of 75 s |
| `llm-model` 0.2.0 | The fleet side: the model only on the peer listener (`<name>-peer`, Exact match), `/healthz/<model>` straight to vLLM with a retry, the shed limit, the classes `interactive`/`standard`/`batch`, flow control with `maxConcurrency` per endpoint and tenants served in turn, aigw-ui's annotations, the alerts |
| new | `storage.mode: cache`: a PVC filled once by a Job (KServe's storage initializer) before the model starts, instead of a download into the node's disk at every start; a values schema; arguments checked to be single tokens |

Not in it: node preparation, local PVs and per-node pull Jobs, the LMCache
engine, the AIPerf Job and the S3 Secret. Those stay in the site charts.
A deployment can use their PVC (`model.uri: pvc://<claim>/<path>`).

## Objects

| Object | Name |
|---|---|
| `LLMInferenceService` | `<name>` (`model.objectName`, else the slug of `model.name`) |
| `AIGatewayRoute` on the peer listener | `<name>-peer` |
| `HTTPRoute` `/healthz/<model.name>` | `<name>-health` |
| `BackendTrafficPolicy` (shed limit, timeout; health retry) | `<name>-peer`, `<name>-health` |
| `InferenceObjective` | `interactive` 10, `standard` 0, `batch` −10 |
| `PersistentVolumeClaim`, `Job` (cache mode) | `<name>-model`, `<name>-download-<hash of uri>` |
| `PrometheusRule` (`alerts.enabled`) | `<name>-flow-control` |

One deployment per namespace: the classes are one per namespace, and
aigw-ui adds `best-effort` next to them.

## Rules kept from the site charts

- Nothing on the client listener. A client reaches the model only through
  aigw-ui's entry route, which checks the key and counts the quota.
- The peer route's match stays `Exact`: aigw-ui finds the model by it.
- `keepAliveSeconds` 75 (vLLM's 5 s met the 3 s health checks: the 503 storm).
- Arguments are single tokens in dot notation; KServe runs them through
  `bash eval`. The chart refuses spaces, quotes, braces and shell characters,
  and sets `--max-model-len`, `--tensor-parallel-size` and the data-parallel
  flags itself.
- `maxSurge: 0` with GPUs.

## Render

    helm lint charts/model-deployer -f gitops/aigw-ui/presets/cpu-small.yaml
    helm template x charts/model-deployer -n llm-x -f gitops/aigw-ui/presets/qwen3.8-27b-l4.yaml

## Tested

On the lab (OpenShift 4.22, KServe 0.21, Envoy Gateway 1.9.2, AI Gateway
1.2.0 patched), 2026-10-24: the render of `deployments/lab/qwen-tiny.yaml`
passed a server-side dry run against the lab's CRDs; the cache Job filled
the PVC from `hf://` in 7 s; qwen-tiny's LLMInferenceService was moved to
the render's spec and served from the PVC. The GPU presets were rendered
and linted only.
