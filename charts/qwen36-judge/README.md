# qwen36-judge-chart

Qwen3.6-35B-A3B-FP8 ("**judge**") served by KServe on the cluster's L4
GPU node, behind the shared Envoy AI Gateway. Its job: an independent
second opinion (different model family than GLM-5.3) for the Claude
Code PreToolUse hook — allow / ask / deny per tool call, ~100 ms.

**Status**: deployed live in namespace `llm-judge` on
`prep-llm-site-a-a`, smoke-tested end-to-end through the VIP (see
docs/RECIPE.md §9). Deployed 2026-10-07.

---

## How to use the model

One endpoint, the gateway VIP `http://192.0.2.7`, serves every model on
this cluster. The `model` field of the request picks the model, and
every request needs a tenant key from aigw-ui:

```bash
curl http://192.0.2.7/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'Authorization: Bearer <tenant key>' \
  -d '{"model":"judge","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

For OpenAI-SDK clients: `base_url = http://192.0.2.7/v1`, `model = judge`.

The path form (`/llm-judge/qwen36-judge/v1/...`) is no longer served to
clients. KServe's route for it is on the gateway's peer listener, which
needs the fleet client certificate.

Rules that bite:
- The request must contain a **user-role message** — the gateway's EPP
  rejects system-only requests with 400 "No user query found".
- Thinking is off server-side (`reasoning_tokens: 0`); the judge
  answers directly in `content`.

## The routes in the namespace

`kubectl -n llm-judge get httproutes` shows three, all on the gateway's
peer listener:

| HTTPRoute | Created by | Purpose |
|---|---|---|
| `qwen36-judge-peer` | this chart (`AIGatewayRoute`) | `x-ai-eg-model: judge` → scheduler (EPP) → InferencePool. The entry route sends requests here |
| `qwen36-judge-peer-health` | this chart | `GET /healthz/judge` → vLLM `/health`, asked by the entry route's health check |
| `qwen36-judge-kserve-route` | KServe llmisvc-controller | Path routing `/llm-judge/qwen36-judge/v1/...`. Unused; pinned to the peer listener so it is not a way past the entry route |

The route clients hit is not in this namespace. aigw-ui writes it
(`fleet-judge` in `envoy-ai-gateway-system`) once the model's entry
route is turned on in the hub.

## Quotas

A `QuotaPolicy` attaches only to an `AIServiceBackend`, never to an
`InferencePool`. Up to chart 0.2.x this chart kept a direct backend for
that reason, and requests to it skipped the scheduler. aigw-ui's entry
route has its own `AIServiceBackend`, so the quota is counted there and
the request still goes through the scheduler. The old direct route is
still in the chart, behind `aigatewayRoute.enabled` and
`openaiBackend.enabled`, both off.

## Claude Code "auto mode guarded by the judge"

`hook/judge.py` + `hook/judge.json` turn Claude Code into an
autonomous agent whose every tool call is verdicted by the judge:

- **allow** → tool runs with no prompt (that's the auto mode)
- **deny** → blocked, reason shown (regex hard-deny layer catches
  catastrophic patterns — node deletes, openshift-*/kube-* namespace
  deletes, rm -rf outside /tmp, mkfs/dd-to-device — before the LLM)
- **ask** → manual user prompt (also the fail-safe: judge down,
  truncated reply, or any internal error NEVER auto-allows)

Wire it up on any host that can reach the VIP:

```bash
mkdir -p ~/.claude/hooks
cp hook/judge.py  ~/.claude/hooks/judge.py && chmod +x ~/.claude/hooks/judge.py
cp hook/judge.json ~/.claude/judge.json      # endpoint, model, api_key, max_tokens, shadow
# then merge into ~/.claude/settings.json:
#   "permissions": {"defaultMode": "acceptEdits"},
#   "hooks": {"PreToolUse": [{"matcher": "*",
#     "hooks": [{"type": "command",
#                "command": "python3 $HOME/.claude/hooks/judge.py",
#                "timeout": 20}]}]}
```

Put a tenant key from aigw-ui into `api_key` in `~/.claude/judge.json`
and `chmod 600` the file. The gateway answers 401 without a key, and
the hook then asks for every tool call.

Verdicts audit-log to `~/.claude/judge.log`. `"shadow": true` in
judge.json observes without enforcing. Hooks load at session START —
restart open Claude sessions after wiring. Deployed and verified on
svc-mgmt.

## What the chart deploys (9 objects)

1. **Namespace** (`llm-judge`) + **ServiceAccount** (`s3sa`) +
   **Role/RoleBinding** + **SCC** (`qwen36-judge-model-serving`,
   cluster-scoped — needs cluster-admin to install).
2. **LLMInferenceService** (`qwen36-judge`) — vLLM, TP2 (2× L4 per
   replica), thinking off, prefix caching, `max_num_seqs 128`
   (Qwen3.6's Mamba layers cap concurrency on 24 GB cards).
3. **AIGatewayRoute** (`qwen36-judge-peer`) on the gateway's peer
   listener: `judge` → InferencePool (scheduler). Requests arrive
   here from aigw-ui's entry route.
4. **HTTPRoute** (`qwen36-judge-peer-health`) for the entry route's
   health check, and a **BackendTrafficPolicy** that tries a check
   again when it meets a connection vLLM is closing.

The KServe controller additionally creates (not chart-managed):
Deployment `qwen36-judge-kserve`, EPP router-scheduler, services,
InferencePool, and its own HTTPRoute (`qwen36-judge-kserve-route`, on
the peer listener). `LLMInferenceService
READY=False WaitingForGateway` is a known cosmetic condition — glm53
has shown it for days while serving fine; trust the VIP.

No PVC, no pull Job: the pod's storage-initializer downloads the
35 GB model from `s3://llms/Qwen/Qwen3.6-35B-A3B-FP8` on every start
(~17 s at measured FlashGrid rates).

## Prerequisites (out-of-band, NOT in this chart)

- **L4 node** in the cluster with the GPU operator (verified:
  `ocp-util-node-1`, 8× L4). No LVMS
  needed — single NVMe, no PVCs used.
- **S3 secret** (real credentials never committed to this repo):
  ```bash
  kubectl -n llm-judge create secret generic judge-s3 \
    --from-literal=AWS_ACCESS_KEY_ID=<key> \
    --from-literal=AWS_SECRET_ACCESS_KEY=<secret>
  kubectl -n llm-judge annotate secret judge-s3 \
    serving.kserve.io/s3-endpoint=http://host.example.internal
  ```
  Served from the shared `llms` bucket — the mce-site-b-bucket keys
  provided for the original request were invalid on every reachable
  endpoint (RECIPE §7).
- **KServe v0.21.0-rc1** llmisvc-controller + presets (ns `kserve`,
  already installed; EPP image patched to the artifactory mirror —
  Argo-managed, may revert).
- **Envoy AI Gateway** (ns `envoy-ai-gateway-system`, installed).

## Install

```bash
helm upgrade --install qwen36-judge . -n llm-judge --create-namespace

# Watch bring-up: storage-initializer download, then vLLM load
# (weights ~25 s + torch.compile/graphs ~3 min; startup probe: 30 min)
kubectl -n llm-judge get pods,llmisvc -w

# Then run the smoke test: docs/RECIPE.md §9
```

Plain manifests if preferred: `helm template qwen36-judge . | oc apply -f -`.

## Operations

```bash
# Tail the judge's own logs (vLLM):
kubectl -n llm-judge logs -f deploy/qwen36-judge-kserve -c main

# Restart / new replica (re-downloads model from S3, ~4.5 min to 1/1):
kubectl -n llm-judge delete pod -l app.kubernetes.io/name=qwen36-judge

# Hook-side audit (on the client host):
tail -f ~/.claude/judge.log
```

**Autoscaling ships OFF** (`llmisvc.scaling.enabled: false`). A
`spec.scaling` block without KEDA + WVA +
`autoscaling-wva-controller-config.prometheus.url` makes the
controller error-loop. Enable only after installing those (RECIPE §6),
then `--set llmisvc.scaling.enabled=true`. Until then: 1 warm replica
(`minReplicas: 1`) — deliberate, the judge must stay hot.

## Uninstall

```bash
helm uninstall qwen36-judge -n llm-judge
kubectl delete scc qwen36-judge-model-serving   # cluster-scoped, not helm-managed
kubectl -n llm-judge delete secret judge-s3     # out-of-band secret
kubectl delete ns llm-judge
```

Nothing is left on GPU nodes (model lived in emptyDir).

## Deep dive

Design rationale, sizing math, the broken-index bucket repair, the
Mamba `max_num_seqs` fix, WVA day-2 install steps, smoke-test
transcripts: **docs/RECIPE.md**.
