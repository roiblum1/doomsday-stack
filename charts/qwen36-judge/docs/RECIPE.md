# Recipe: Qwen3.6-35B-A3B-FP8 as the "judge" on the L4 server

Target: hosted cluster `prep-llm-site-a-a` (OCP 4.22 / k8s 1.35), the one
serving GLM-5.3 on 2× B200. A new L4 GPU server (8× L4) joins this
cluster and runs the judge for the Claude Code PreToolUse hook.

Status: chart built (`qwen36-judge-chart`), not yet deployable — two
blockers below (S3 endpoint, WVA/KEDA install). Everything else is
wired for the day the L4 node appears.

## 1. Why this model

| Decision | Reason |
|---|---|
| Qwen3.6-35B-A3B (MoE, 3B active/token) | Smarter than any dense model that fits one L4; with only 3B active params it decodes/prefills faster than a dense 9B. |
| Different family from GLM | The judge must not be the agent grading itself. |
| FP8 weights ≈ 35 GB | Does not fit one 24 GB L4; fits 2× L4 with ~6 GB/GPU left for KV cache at 16k context. |
| Apache 2.0, released Apr 2026 | — |

Rejected alternatives:
- **Qwen3.5-9B FP8 (1-GPU replicas)**: viable fallback if the L4s run
  out; weaker and slower per token than 35B-A3B; scale 1→8 in
  single-GPU steps.
- **gpt-oss-safeguard-20b**: purpose-built for policy judging, but
  vLLM's gpt-oss recipe still lists Ada-class GPUs (L4) as WIP.

## 2. Sizing: 2× L4 per replica, TP2, 1→3 replicas

- **TP2, not wider**: L4s are PCIe cards with no NVLink; tensor
  parallelism beyond 2 only adds PCIe traffic. All parallelism lives in
  one pod via `spec.parallelism.tensor: 2` (the kserve base preset
  renders `--tensor-parallel-size 2` from it).
- **Replicas = GPU pairs**: 8 L4s on the server → max 4 replicas. We
  cap at **3** (6 GPUs) leaving **2 L4s for the RAG embedder/reranker**.
- **minReplicas stays 1**: a cold judge pod takes minutes (weights +
  CUDA graphs); during that window every hook call would time out and
  fall back to asking the human. The judge must never be scaled to zero.
- Resources per replica: `nvidia.com/gpu: 2`, 16/32 CPU, 64/128Gi RAM.

## 3. vLLM arguments (rendered by the chart)

The kserve base preset (`kserve-config-llm-template`) evals
`vllm serve /mnt/models --served-model-name judge
publishers/llm-judge/models/judge --port 8000 ... "$@"`, so args are
single tokens and JSON blobs need single-quote wrapping (bash brace
expansion — same trap glm53-chart solved for `--kv-transfer-config`).

| Flag | Why |
|---|---|
| `--max-model-len=16384` | Judge calls = policy (~2-4k) + recent requests + tool calls + pending call. 16k covers it; every extra token steals KV headroom on 24 GB cards. |
| `--max-num-seqs=128` | **Found the hard way**: Qwen3.6's hybrid linear-attention (GDN/Mamba) layers need one state block per decode sequence; the default max_num_seqs (256) exceeded available Mamba blocks (~175) on 24 GB L4s → crash at CUDA-graph capture. 128 ≫ judge concurrency, KV cache still ~161k tokens. |
| `--reasoning-parser=qwen3` | Splits Qwen's think-blocks into `reasoning_content` so reasoning never leaks into the tool-visible `content` field. |
| `--default-chat-template-kwargs='{"enable_thinking": false}'` | Thinking OFF: the judge answers in a fixed schema; reasoning tokens would burn latency and the output budget. (Template-arg, not a request-time kwarg, so hook clients can't re-enable it.) |
| `--limit-mm-per-prompt='{"image":0,"video":0}'` | Text-only judge: close multimodal input paths. |
| `--enable-prefix-caching` | The hook always sends the same system prompt + policy first → those tokens are nearly free on every call. |
| `--trust-remote-code` | Qwen custom code paths (proven on the qwen-3-5-35b-a3b deployment). |

Deliberately absent:
- **No `--served-model-name`** — the preset sets it (`judge` +
  `publishers/llm-judge/models/judge`).
- **No `--tensor-parallel-size` in args** — `spec.parallelism.tensor`
  renders it; a duplicate flag would be a footgun.
- **No tool-call parser** — the judge returns verdict JSON, not tool calls.
- **Day-2 latency lever — MTP speculative decoding**: the model dir
  ships `mtp.safetensors` (Qwen multi-token-prediction head). Once the
  baseline works, try
  `--speculative-config='{"method":"eagle","model":"/mnt/models/mtp.safetensors",...}'`
  style config (vLLM version-dependent) — judge p95 latency is the
  metric that matters. Not enabled day-1: speculative decode interacts
  with FP8-on-L4 numerics and needs its own smoke test.
- **No `--kv-transfer-config` / LMCache / Mooncake** — user call. Only
  this deployment's own pods could ever share its KV cache (nothing else
  serves `judge`), vLLM's prefix cache already covers the repeated
  system prompt, and LMCache would pin the image to an LMCache build.
  Add later only if prefix-cache hit rates measurably disappoint.
- **No `NCCL_IB_*` RoCE tuning** — TP2 stays inside one node over PCIe;
  the chart only sets `NCCL_IB_DISABLE=1` so NCCL never wanders onto
  RoCE. (The preset's `KSERVE_INFER_ROCE` inference stays dormant
  because the workload env doesn't set it.)

Image: `registry-internal/vllm/vllm-openai:v0.30.0`
— newest plain (non-LMCache) vllm-openai mirrored in artifactory; bundles
flashinfer cubins (air-gap requirement, per glm53-chart's node-prep
notes). ⚠ Verify Qwen3.6-A3B arch support at smoke test; if the arch is
unknown to v0.30.0, mirror a newer vllm-openai build — the args above
are all ≥ v0.22-era flags.

## 4. Storage: s3:// direct via the storage-initializer (no PVC)

Deviation from glm53-chart — and from the original plan in this recipe.
The L4 server joined with a **single NVMe**, so LVMS (needs ≥2) does
not cover it and `lvms-vg1` PVs cannot bind there. Options were:

| Option | Verdict |
|---|---|
| **s3:// + storage-initializer** (chosen) | Proven on this fleet's L4 nodes (qwen-3-8-27b-fp8, qwen3.5-35b-a3b): the controller injects an init container that downloads the model into an emptyDir at `/mnt/models` every pod start. 35 GB at the ~3 GB/s FlashGrid rates measured for glm53 ≈ well under a minute. Restart cost is negligible (restarts are rare; the judge's availability requirement is about the *steady state*, which WVA keeps at minReplicas=1 warm). |
| glm53 node-prep + static local PVs | Rejected: a privileged host-mount DaemonSet + static PV + nodeAffinity to persist data the pod could just fetch in <1 min. Pure complexity for a single-node, 35 GB, occasionally-restarting workload. |
| HostPath direct | Rejected: LLMInferenceService `spec.template` would need the volume wiring through the preset; uglier than one initContainer override for strictly less benefit. |

The chart pins the storage-initializer **image override**
(`registry-internal/kserve/kserve/storage-initializer:v0.21.0-rc1`) via
`spec.template.initContainers`: the cluster's `inferenceservice-config`
defaults to docker.io `kserve/storage-initializer:latest` and the IDMS
mirrors only nvcr.io / quay.io-ocp / registry.redhat.io — **not
docker.io**. The controller merges the override (image/resources win,
args/command stay the controller's; verified in
`pkg/controller/v1alpha2/llmisvc/workload_storage.go`). A cleaner
cluster-level fix is patching `inferenceservice-config`
`storageInitializer.image` to the artifactory mirror — not done here
because that ConfigMap is platform-managed (same Argo-revert risk as
the preset patches).

Credentials: the controller reads the **secret linked to the workload
ServiceAccount** (`s3sa` → `judge-s3`) and injects `AWS_ACCESS_KEY_ID`/
`AWS_SECRET_ACCESS_KEY` from its data plus `AWS_ENDPOINT_URL` from the
`serving.kserve.io/s3-endpoint` secret **annotation** (http:// prefix
⇒ plain HTTP, matching the FlashGrid endpoints). Verified in
`pkg/credentials/s3/s3_secret.go` + `utils.go`.

## 5. Routing

Same shared gateway as GLM-5.3 (VIP 192.0.2.7): one
`AIGatewayRoute` rule matches header `x-ai-eg-model: judge` (the
extproc also derives it from body `model`) → the judge's
InferencePool (EPP path). The KServe router HTTPRoute adds path-based
`/llm-judge/qwen36-judge/...` for free.

- No native Anthropic backend / `claude-*` alias (that exists for
  Claude Code ↔ GLM); the judge hook speaks OpenAI.
- No custom EPP scheduler profile (unlike glm53's DP8 multi-port setup):
  plain TP2 exposes one port 8000 per pod, so the default
  queue/kv-cache scorers work. The EPP ServiceAccount is pinned to
  `s3sa` — same OCM dockercfg-adoption fix glm53 needed on this cluster.
- Timeout 600s (glm53 needs 3600s for 262k-token thinking requests; the
  judge sees ≤16k-token prompts, thinking off).

## 6. Autoscaling: WVA → KEDA → HPA (shipped OFF)

`spec.scaling` (schema verified against the live v1alpha2 CRD):

```yaml
scaling:
  minReplicas: 1
  maxReplicas: 3
  wva:
    keda:
      pollingInterval: 5
      cooldownPeriod: 30
```

WVA drives KEDA on vLLM queue depth + KV-cache usage. KServe's
installer exposes this as `kserve-install.sh --scaling keda`.

**LIVE FINDING (2026-10-07, first install)**: the scaling block is NOT
inert on a cluster without WVA/KEDA. The llmisvc-controller
error-loops:

```
Reconciliation failed: ... failed to reconcile scaling: failed to
reconcile main workload scaling: failed to reconcile main actuator:
autoscaling-wva-controller-config.prometheus.url is required in
inferenceservice-config when using KEDA
```

The workload itself still deploys and serves, but the reconcile error
loop is dirty and downstream status is unreliable. So the chart ships
`llmisvc.scaling.enabled: false` (renders plain `replicas: 1`) and the
block is flipped on as a day-2 upgrade once ALL of these exist:

1. **KEDA** (Custom Metrics Autoscaler / kedacore chart **2.18.0**,
   ns `keda`).
2. **WVA controller**: `oci://ghcr.io/llm-d/workload-variant-autoscaler`
   **v0.7.0**, ns `wva-system`, pointed at a Prometheus that scrapes
   the judge pods.
3. **`inferenceservice-config`** (ns `kserve`) must carry
   `autoscaling-wva-controller-config.prometheus.url` — the exact key
   the controller demands. Platform-managed ConfigMap: coordinate the
   patch with the platform team (same Argo-revert risk as the preset
   patch). Value = the user-workload monitoring Prometheus (already
   enabled on this cluster), e.g.
   `https://thanos-querier.openshift-monitoring.svc:9091` or the
   user-workload route, depending on how WVA authenticates.
4. **Air-gap mirroring** before all of the above: mirror the KEDA chart
   + images (`keda-operator`, `keda-metrics-apiserver`, `keda-webhook`)
   and the WVA chart + controller image into registry-internal
   (oc-mirror or skopeo; see the registry-mirroring brain page for the
   shared-registry caveat).

Then:

```bash
helm upgrade --install qwen36-judge . -n llm-judge \
  --set llmisvc.scaling.enabled=true
```

Do **not** set `spec.replicas` alongside `scaling`.

## 7. Getting the model in — RESOLVED via the shared `llms` bucket

Original ask: `s3://mce-site-b-bucket/Qwen3.6-35B-A3B-FP8/` (access key
+ secret key provided with the task).

**What the investigation found (2026-10-07):**

- The provided credentials are rejected with `InvalidAccessKeyId` on
  **every** S3 endpoint reachable from this cluster
  (s3-endpoint-internal-{zone-a1,zone-a2,site-b-r1,site-a-r1,zone-b1,zone-b2},
  s3-endpoint-internal, s3-endpoint-internal-{site-a}, eck-internal-* on dok-internal).
  The known-good `llms` bucket on zone-a1 was the control — method sound.
- The `mce-site-b-bucket` **bucket exists** (403 with valid foreign creds)
  on zone-a2, site-b-r1, site-a-r1, zone-b1, stage-zone-a2, zone-c1 — only its
  keys are dead.
- The **identical model directory** (57 objects, 34.9 GB, config.json /
  tokenizer.json / tokenizer_config.json / generation_config.json /
  all layer safetensors) already sits in the shared
  `llms` bucket: `s3://llms/Qwen/Qwen3.6-35B-A3B-FP8`, reachable on
  **zone-a1** with the credentials already used in-namespace by glm53
  (site-a-r1 rejects that key — zone-a1 is the endpoint that works).

**Decision**: serve from `llms` now — same weights, working keys, no
waiting on a credentials fix. When valid `mce-site-b-bucket` keys
arrive, flip `model.uri` + the `judge-s3` secret (endpoint annotation
and keys) and `helm upgrade`; nothing else changes.

**First-load crash — repaired in the bucket (2026-10-07)**: this
model dir is a custom per-layer re-shard (`layers-0..39.safetensors`,
`outside.safetensors` = embeddings/lm_head/vision towers,
`mtp.safetensors` = speculative head), but it still carried the
ORIGINAL `model.safetensors.index.json` referencing the
`model.safetensors-000XX-of-00014` names. vLLM trusts the index →
`FileNotFoundError: Weight files referenced in index but missing` →
crash loop. Fix: regenerated the index from the actual safetensors
headers (64,196 tensors → 42 files, 5.9 MB) and uploaded it to
`s3://llms/Qwen/Qwen3.6-35B-A3B-FP8/model.safetensors.index.json`
(original kept alongside as
`model.safetensors.index.orig-broken.json` for rollback). Anyone
serving OTHER per-layer-resharded models from `llms` will hit the same
thing — check the index before blaming vLLM.

Sanity-check any new source before switching:
`s5cmd --endpoint-url http://<host> ls s3://<bucket>/Qwen3.6-35B-A3B-FP8/`
(expect ~35 GB of safetensors + config/tokenizer files, and an index
whose weight_map actually names those files).

## 8. Bring-up order

1. Node joins the cluster (done 2026-10-07:
   `ocp-util-node-1`, 8× L4 allocatable,
   GPU driver 580.126.20 / CUDA 13.0, label
   `nvidia.com/gpu.product=NVIDIA-L4`). No LVMS needed — see §4.
2. Create the `judge-s3` secret + endpoint annotation (README §Install).
3. `helm upgrade --install qwen36-judge . -n llm-judge --create-namespace`.
4. Watch the storage-initializer download (init container logs), then
   the vLLM startup probe.
5. Run the smoke test (below). **Keep the judge hook in shadow mode**
   (`"shadow": true`) until it passes.
6. Install WVA/KEDA (§6) → confirm the ScaledObject appears and
   `kubectl -n llm-judge get hpa` tracks load.

**Two HTTPRoutes in the namespace is expected** (same as glm53):
`qwen36-judge` (owner `AIGatewayRoute`, from this chart) matches the
`x-ai-eg-model: judge` header on any path and routes through the EPP;
`qwen36-judge-kserve-route` (owner `LLMInferenceService`, created by
the KServe controller from `spec.gates`) exposes the path-based
endpoints `/llm-judge/qwen36-judge/v1/...` and
`/publishers/llm-judge/models/judge/v1/...` directly. They attach to
the same Gateway but match on non-overlapping conditions — not a
duplicate, not a leak.

## 9. Smoke test (the gate before enforcement)

**Executed 2026-10-07 — PASSED** (external VIP 192.0.2.7):

```bash
# 1. Plain completion — model answers, no thinking in the response:
curl -s http://192.0.2.7/v1/chat/completions \
  -H 'content-type: application/json' -H 'x-ai-eg-model: judge' \
  -d '{"model":"judge","messages":[{"role":"user","content":"Reply with the single word: ready"}],"max_tokens":8}'
#    -> content "ready", reasoning: null, reasoning_tokens: 0, HTTP 200,
#       system_fingerprint vllm-0.30.0-tp2

# 2. Judge behavior (system policy + tool-call question):
#    -> content "Allow.", reasoning None, ~95-100 ms end-to-end (VIP ->
#       gateway -> EPP -> vLLM), consistent across repeat calls

# 3. EPP QUIRK (llm-d extproc): a request whose messages contain ONLY a
#    system role is rejected with HTTP 400 "No user query found in
#    messages." — every request must include a user message. The judge
#    hook always sends one; curl-based debugging must too.

# 4. Reasoning parser + thinking-off: verified via reasoning: null and
#    reasoning_tokens: 0 in the responses above.
# 5. Judge path: run the hook's own test suite against the real endpoint
#    (it was only tested against a mock judge): expect 26/26.
# 6. Latency budget: verdict p95 must stay inside the hook's timeout.
```

Startup profile (measured, cold): storage-initializer download 16.6 s
(35 GB, 2.1 GB/s), weight load 23 s, torch.compile + CUDA graphs
~2.5 min → pod 1/1 in ~4.5 min after image pull.

Then point `judge.json` at it: `base_url: http://192.0.2.7`,
`model: judge` (+ the CA bundle / `ca_bundle` field per the hook's
config), and flip `shadow` off.

## 10. Risk register

| Risk | Status (2026-10-07) |
|---|---|
| **FP8 kernels on L4 (Ada, sm89)** | **RESOLVED**: MarlinFP8 scaled-mm kernel selected, engine healthy, verdict latency ~95 ms. |
| vLLM v0.30.0 lacks the Qwen3.6-A3B arch | **RESOLVED**: arch resolves as `Qwen3_5MoeForConditionalGeneration`; GDN kernels active. |
| Hybrid linear-attention (Mamba) state blocks vs max_num_seqs | **RESOLVED**: `--max-num-seqs=128` (was crashing at 256 > 175 blocks). |
| Stale `model.safetensors.index.json` in the llms copy | **RESOLVED in-bucket** (§7); original kept as `*.orig-broken.json`. |
| WVA/KEDA never installed. | Judge stays at 1 replica — degraded capacity, no correctness impact. |
| Second L4 server joins later. | Storage is now PVC-free (s3:// per pod) — a second node needs nothing but capacity; the chart scales to 3 replicas regardless of node count. |
| EPP preset image reverted by Argo. | Same known issue as glm53 — re-patch `kserve-config-llm-scheduler` when EPP pods ImagePullBackOff. |

## 11. Sources

- glm53-chart (this cluster's proven B200 deployment; storage, pull-job,
  SCC, gateway and preset-merge patterns all come from it)
- Running instance: `glm53-b200` LLMInferenceService, ns `llm-glm53`
- KServe v0.21.0-rc1 llmisvc-controller + presets on this cluster;
  kserve-master `hack/setup/*` for WVA/KEDA install specifics
- Proven L4 prior art: `kserve/qwen3.5-35b-a3b/llmisvc.yaml`,
  `qwen-3-8-27b-fp8` chart (runtimeClassName/priorityClassName omission,
  probe budgets, VLLM_ADDITIONAL_ARGS style)
- vLLM recipe: Qwen3.6-35B-A3B; Qwen/Qwen3.6-35B-A3B-FP8 model card;
  KServe v0.19+ LLMInferenceService autoscaling (via the agent
  conversation that scoped this task)
