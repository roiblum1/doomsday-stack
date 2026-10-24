# model-deployer

One chart for every model on a serving site of an aigw-ui fleet. A model is
values, layered by the Argo CD platform (argocd-day2-platform):

| Layer | Who writes it | Holds |
|---|---|---|
| `gitops/app-of-apps/operators/<model>/values.yaml` | people, or aigw-ui's Deployments page ("Edit recipe", "New model") | the recipe: images, parallelism, vLLM and LMCache flags, the S3 path of the weights |
| the site's layers (`sites/<site>/…/values.yaml`, `defaults/hosted-clusters/<model>/…`) | people | what a site or environment shares |
| `sites/<site>/<env>/mces/<mce>/<cluster>/<model>/values.yaml` | aigw-ui's Deployments page ("Deploy", "Edit"), or people | what differs on that cluster; the directory is the registration |

`operators/<model>/<model>.yaml` points the model's Argo CD app at this chart
(`repourl` `…/model-deployer-chart.git`). aigw-ui writes only what differs
from the layers below, so a recipe change still reaches every cluster.

## What it deploys

From `generic-model` (each piece gated on values), which rendered the
per-model charts byte for byte:

- `Namespace` with `aigw-ui.io/serving: "true"` (the peer listener's selector) and,
  with the LMCache ServiceMonitor, `openshift.io/cluster-monitoring`;
  `namespaceCreate: false` for a namespace that holds other things;
- node preparation DaemonSet (LVM LVs, VG from blank disks, flashinfer
  cubins), static local PVs and PVCs, per-node S3 pull Jobs (`model.subPath`,
  `model.s3.path`, `pullJobs`, `nodePrep`, `storage`);
- the LMCache engine (RAM L1 + disk L2), its ServiceAccount, SCC binding,
  monitoring RBAC and PrometheusRule (`lmcache`);
- the SCC for root with IPC_LOCK (`scc`, `llmisvc.ipcLock`), the S3 Secret
  (`s3.create`, testing only), the AIPerf Job (`aiperf`);
- the `LLMInferenceService`: any parallel shape (tensor parallel through
  `llmisvc.parallelism.tensor` or the flags, data parallel with one port per
  rank through `llmisvc.scheduler.pool`), WVA/KEDA scaling, KV offloading.

From the fleet charts (`glm53-bundled`, `llm-model`), on the gateway's peer
listener only:

- `AIGatewayRoute <name>-peer` (Exact match on the model name) to the
  InferencePool, `HTTPRoute <name>-health` (`/healthz/<model>` straight to
  vLLM) with a retry, the shed limit (`peer.maxParallelRequests`);
- the classes `interactive` 10, `standard` 0, `batch` −10;
- flow control merged into the model's own scheduler config
  (`llmisvc.flowControl`: `maxConcurrency` per endpoint, tenants in turn);
- `VLLM_HTTP_TIMEOUT_KEEP_ALIVE` 75 (`llmisvc.keepAliveSeconds`), KServe's own
  route on the peer listener (`gateway.aiGateway.kserveRouteListener`);
- aigw-ui's annotations: `capacity-per-instance`, `model-revision`,
  `max-model-len`, `market-id` (`model.*`).

New: `modelCache` for a cluster without node disks: a PVC from the
cluster's storage class, filled once by a Job (KServe's storage initializer,
`hf://` or `s3://`) before the model starts (Argo CD sync wave −1).

Not rendered any more: the client-listener `AIGatewayRoute` and the direct
backends of `generic-model` (`aigatewayRoute`, `directBackend`). Every
request takes aigw-ui's entry route.

## One model, a shape per cluster

The recipe holds what is the model's (weights, image, its vLLM and LMCache
flags); each cluster's own file holds its shape. `shapes/` has three, each
rendered with glm53's recipe:

| File | Shape | What it sets |
|---|---|---|
| `shapes/b300-dp8.yaml` | whole B300 nodes, DP8 with EP inside the node | `llmisvc.dataParallelExternalLB.ranks: 8` (the DP flags, a pool of ports 8000-8007, supervisor probes), `extraArgs: [--enable-expert-parallel]` |
| `shapes/h200-tp8.yaml` | whole H200 nodes, TP8 | `llmisvc.parallelism.tensor: 8` |
| `shapes/h200x2-roce-dp8-tp2-ep16.yaml` | one replica over 2 H200 nodes on RoCE, DP8 TP2 EP16 | `llmisvc.multiNode: true` (KServe's LeaderWorkerSet), `parallelism: {data: 8, dataLocal: 4, tensor: 2, expert: true}`, `roce: true`, the RDMA network in `podAnnotations`, the RDMA resource, and NCCL settings that replace the recipe's single-node ones (maps merge) |

`cluster-llm-prep`'s `glm53/values.yaml` is the B200 DP8 shape, moved out of
the recipe; recipe and shape together render exactly what the recipe alone
rendered before the move.

A cluster adds flags with `llmisvc.extraArgs` (rendered before the recipe's
`args`): Helm replaces lists, so a cluster that sets `args` repeats them all.

## Rules

- Nothing on the client listener; the peer route's match stays `Exact`.
- `llmisvc.args` are single tokens in dot notation, or `--option='value'`
  with no single quote inside (KServe runs them through `bash eval`); the
  render fails otherwise. `--kv-transfer-config` is the chart's (LMCache).
- The vLLM image and the LMCache image are the same build; `lmcache.server.chunkSize`
  is tied to the model and its TP shape (`chunkSizeModulus` guards it).
- `maxSurge: 0` on GPU recipes (the default); a CPU recipe sets
  `llmisvc.rolloutStrategy: null`.
- A Job's pod template cannot change: the download Job's pod labels are fixed
  and its name carries a hash of uri and image; the per-node pull Jobs carry
  the chart's version, so model apps ignore `/spec/template/metadata/labels`
  of Jobs (`ignoreDifferences` in `operators/<model>/<model>.yaml`).

## Migration from glm53-bundled, qwen38-bundled, qwen36-judge

`operators/{glm53,qwen38,qwen36-judge}/values.yaml` are `generic-model`'s
examples without the client-listener parts, with the peer names of each old
chart and `llmisvc.ipcLock: true`. Rendered against the old charts
(`helm template`, 2026-10-24), the only differences are:

- the classes `interactive`/`standard`/`batch` (the old charts had none) and
  the annotation `aigw-ui.io/capacity-per-instance: "1"`;
- `helm.sh/chart` labels, and the node-prep script's comment wording
  (`generic-model`'s merged text; the DaemonSet rolls once);
- glm53: the recipe is the `bundled` branch the app deploys (LMCache
  v0.5.5 engine and image), not the export's `glm53-bundled` copy of `main`
  (KV offloading).

The examples lacked `--enable-prompt-tokens-details` and
`--enable-force-include-usage`; the recipes have them (aigw-ui charges cached
tokens and streamed answers from them).

## Render

    helm lint charts/model-deployer -f gitops/app-of-apps/operators/qwen38/values.yaml
    helm template x charts/model-deployer --kube-version 1.32.0 \
      -f gitops/app-of-apps/operators/glm53/values.yaml

## Tested

On the lab (OpenShift 4.22, KServe 0.21, Envoy Gateway 1.9.2, AI Gateway
1.2.0 patched), 2026-10-24: qwen-tiny's recipe
(`operators/qwen-tiny/values.yaml`) renders the 10 objects it runs, and a
server-side dry run against the lab's CRDs accepted them; the download Job
filled the PVC from `hf://` in 7 s; qwen-tiny served from the PVC
(`max_model_len` 8192, cached-token details in `usage`). The GPU recipes
and the three shapes were rendered, linted and compared with the old charts
only; none ran on GPUs (multi-node and RoCE included).
