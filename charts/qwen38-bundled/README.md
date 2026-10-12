# qwen38-chart

Qwen3.8-27B-FP8 on the L4 node, served by KServe vLLM with **LMCache**
KV-cache offloading (not Mooncake), managed by ArgoCD.

Sister chart of `glm53-chart` (same pattern, one node, 6 GPUs): where the
two differ, the reason is noted below. See the glm53-chart README for the
long-form storage/protocol rationale -- the geometry here is identical.

## What lands in the cluster

| Object | Name | Notes |
|---|---|---|
| Namespace | `llm-qwen38` | label `openshift.io/cluster-monitoring=true` for the platform Prometheus |
| LLMInferenceService | `qwen38-l4` | 1 pod, TP2 x DP3 = 6x NVIDIA L4, runtimeClass `performance-...-l4` |
| LMCacheEngine | `qwen38-cache` | DaemonSet (1 pod), L1 200Gi pinned RAM + L2 900Gi on a local LV |
| Static PVs/PVCs | `qwen38-models` 200Gi, `qwen38-cache` 150Gi, `qwen38-cache-l2` 1000Gi | local `StorageClass qwen38-local-static`, nodeAffinity-pinned |
| node-prep DaemonSet | `qwen38-node-prep` | privileged nsenter; creates VG + LVs, keeps them mounted, seeds flashinfer cubins |
| Model pull Job | `qwen38-pull-<node>` | s5cmd from `s3://llms/Qwen/Qwen3.8-27B-FP8/` (28.8G) |
| SCC | `qwen38-model-serving` | cluster-scoped; own copy, no glm53 dependency |
| PrometheusRule | `qwen38-cache` | engine-down / no-targets / L2-high / L1-pressure / no-lookups |

External endpoint (shared Envoy AI Gateway, VIP 192.0.2.7):

```
http://192.0.2.7/llm-qwen38/qwen38-l4/v1/models
http://192.0.2.7/llm-qwen38/qwen38-l4/v1/chat/completions
```

Grafana: the shared `lmcache-observability` dashboard (monitoring-chart) --
select namespace `llm-qwen38` / job `qwen38-cache-metrics` in its variables.

## Sizing decisions (and why they differ from glm53 / the reference)

- **Node**: one `NVIDIA-L4` R760xa, 8 GPUs / 128 CPU / ~439Gi allocatable RAM /
  one blank 1.7T data disk (`/dev/sda`; boot is sdb). 2 GPUs are taken by
  `qwen36-judge`, so this chart uses **6 GPUs**.
- **TP2, not TP4**: the model (`Qwen3_5ForConditionalGeneration`,
  config.json: 24 attention heads / **4 KV heads** / head_dim 256) requires
  TP to divide BOTH head counts; 4 KV heads admit TP in {1,2,4}. TP2xDP3
  fits the 6 free GPUs (the reference's TP4xDP2 needed 8).
- **`--max-model-len=65536`** (model max 262144): hybrid attention -- only
  16 of 64 layers hold KV (48 are linear_attention) at 64KiB/token. At TP2
  a full-length sequence's KV (16GiB/GPU) exceeds the per-GPU pool
  (~7.6GiB free after ~14.4GiB fp8 weights at util 0.90); 65536 -> 4GiB.
  More context comes from LMCache L1/L2, not the GPU pool.
- **`--kv-cache-dtype=fp8_e4m3` (glm53 parity)**: same image, same LMCache
  stack as glm53 proves fp8 KV end to end there; halves KV memory (a
  65536-len sequence is 2GiB/GPU at TP2) and doubles L1/L2 token density.
  If the hybrid-attention arch ever rejects it, drop the flag (bf16 fits
  too at 4GiB/GPU).
- **No speculative decode**: the checkpoint has MTP layers but the
  reference deployment did not enable them; keep parity.
- **Storage from scratch**: the B200 nodes' `vg1` comes from day-1
  `/dev/md/lvmdata`; the L4 node ships `/dev/sda` blank, so node-prep's
  `ensure_vg` pvcreate/vgcreate's it first (refusing any disk with
  partitions/filesystem signatures). LVs: models 200G (model is 28.8G),
  cache 150G, l2 1000G.
- **L1 200Gi** (~46% of allocatable RAM; ~3.3M KV tokens at 64KiB/tok):
  engine request 205Gi. Node requests after deploy ~338Gi of 439Gi.
- **Images in lockstep**: isvc main container AND the engine CR both run
  `lmcache/vllm-openai:v0.5.5` (lmcache 0.5.5 + vLLM 0.29.0 -- supports
  `Qwen3_5ForConditionalGeneration`, verified in the image registry).
  node-prep's cubin donor stays `vllm-openai:v0.30.0`.

## Deployment / operation

Prerequisite (out-of-band, once): the S3 secret -- same keys as
`llm-glm53/glm53-s3`:

```sh
oc -n llm-glm53 get secret glm53-s3 -o json \
  | jq '.metadata.namespace="llm-qwen38" | .metadata.name="qwen38-s3"
        | del(.metadata.uid,.metadata.resourceVersion,
              .metadata.creationTimestamp,.metadata.managedFields)' \
  | oc apply -f -
```

Deployed by ArgoCD (registration in `sigs/popai`: `operators/qwen38/` +
site dir under `sites/site-a/prep/mces/cluster-mce-prep/cluster-llm-prep/qwen38/`).
Render check: `helm template qwen38 . --kube-version 1.33.0`.

Ordering (sync waves + operator): namespace/SA/SCC/PV/PVC + node-prep
(VG/LVs) -> pull job (28.8G model) -> engine CR (wave -1) -> isvc. The
vLLM pod takes ~10-20 min from image pull to /health (model load + JIT +
graph capture); startupProbe allows 30 min.

Operations runbook (engine roll, L2 wipe, resize) -- same as glm53-chart's
README, with names substituted. Key points:
- after an engine pod roll, recycle the vLLM pod once (stale ZMQ sessions
  otherwise serve uncached; watch `lmcache_mp_lookups_requests_total`);
- L1 resize = change `lmcache.l1.sizeGB`; L2 resize = LV/PV/capacity all
  three (and expect a cold cache);
- `helm uninstall` retains the PVs (`Retain`): deleting them + the LVs
  (`lvremove vg1/llm-models vg1/llm-cache vg1/llm-l2`, drop the fstab
  lines) is the full wipe.

## Gotchas found while bringing this up (all verified live)

- **`chunkSize` must be a multiple of 784**: `Qwen3_5`'s hybrid
  linear/full attention makes vLLM 0.29 pad its scheduler block to 784
  tokens; the CRD default (256) dies at connector init with
  `LMCache chunk size 256 must be a multiple of 784`. The chart renders
  `spec.server.chunkSize: 1568` explicitly (the template MUST keep
  emitting it) and fails the render otherwise. Side effect: prompts
  shorter than one chunk never store/lookup anything
  (`lmcache_mp_lookup_early_exit_requests_total{reason="empty_chunk_hashes"}`).
- **No external/multi-port DP LB**: vLLM 0.29 gates
  `--data-parallel-multi-port-external-lb` on `model_config.is_moe`,
  false for this arch. Plain `--data-parallel-size=3` (internal LB)
  runs 3 EngineCore ranks behind 3 API servers all sharing `:8000`
  (SO_REUSEPORT, verified in `run_multi_api_server`). Pool and probes
  target port 8000 only.
- **`/readyz` does not exist in vLLM 0.29** (404): the readinessProbe
  uses `/health`.
- **The kserve controller writes `InferencePool.spec.targetPorts` only
  at pool creation**: changing the ports in the isvc later does NOT
  propagate (pool stays gen=1 with the old 8000-8002 list, and the EPP
  keeps registering dead ports -> envoy 503s on 2 of 3 picks). If you
  ever change the ports, patch the pool live:
  `oc -n llm-qwen38 patch inferencepool qwen38-l4-inference-pool
  --type merge -p '{"spec":{"targetPorts":[{"number":8000}]}}'`.
  A recreated pool reads the current isvc, so this is only needed for
  in-place changes.
- **`isvc Ready=False` on `InferencePoolReady` is cosmetic here**: the
  envoy-ai-gateway never writes acceptance conditions on pools (glm53's
  pool shows the same); the HTTPRoute `Accepted`+`ResolvedRefs` plus
  workload endpoints are the real serving path.
- **Envoy injects trace headers**; vLLM logs a harmless
  "request with trace context but tracing is disabled" WARNING.
