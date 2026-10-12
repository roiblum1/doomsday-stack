# One way to every model: the entry route

Written 2026-10-13. This page describes a change to the charts and values
in this repo, the order in which to apply it to the cluster, and what was
tested. Nothing in it has been applied to the real cluster.

`live-cluster/` is still the snapshot of 2026-10-12 and shows the old
paths. `docs/ARCHITECTURE.md` §7.2 and §7.3 describe that snapshot.

## The path after the change

Every request, in either protocol, takes one path:

```
client
  -> VIP, listener "http"
       entry route fleet-<model>, written by aigw-ui:
       key check, quota, choice of site, Anthropic to OpenAI translation
  -> mTLS -> listener "peers"
       <model>-peer, from the model's chart
  -> scheduler (llm-d EPP)
  -> vLLM
```

Clients send `/v1/chat/completions` or `/anthropic/v1/messages` with a
tenant key and the model's name: `glm-5.3`, `Qwen3.8-27B-FP8` or `judge`.

## What skips the entry route today

From `live-cluster/`. All of these are on the client listener.

| Route | Matches | What it skips |
|---|---|---|
| `llm-glm53/glm53-anthropic-alias` | `glm-5.3` with any `anthropic-version` header | quota, scheduler |
| `llm-glm53/glm53`, rule `claude-alias` | `^claude-.*$` | quota, scheduler |
| `llm-glm53/glm53-b200-kserve-route` | path `/llm-glm53/glm53-b200/...`, with `glm53-internal-key` | quota, tenant identity |
| `llm-qwen38/qwen38`, rule `anthropic-native` | `Qwen3.8-27B-FP8` | scheduler (a quota is counted on its backend) |
| `llm-qwen38/qwen38`, rule `openai-epp` | `publishers/llm-qwen38/models/Qwen3.8-27B-FP8` | quota |
| `llm-qwen38/qwen38`, rule `claude-alias` | `^claude-.*$` | never used: the GLM-5.3 route with the same pattern is older and wins |
| `llm-qwen38/qwen38-l4-kserve-route` | path `/llm-qwen38/qwen38-l4/...`, any tenant key | quota |
| `llm-judge/qwen36-judge`, rule `openai-direct` | `judge` | scheduler (a quota is counted on its backend) |
| `llm-judge/qwen36-judge`, rule `openai-epp` | `publishers/llm-judge/models/judge` | quota |
| `llm-judge/qwen36-judge-kserve-route` | path `/llm-judge/qwen36-judge/...`, any tenant key | quota |

The Anthropic backends existed because the gateway lost a model's
thinking when it translated Anthropic to OpenAI. Gateway patch 0004 fixes
that, so the reason is gone.

## What changed in this repo

**The three model charts** (`glm53-bundled`, `qwen38-bundled`,
`qwen36-judge`), the same change in each:

| File | Change |
|---|---|
| `templates/peer.yaml` (new) | `<model>-peer` on the peer listener to the scheduler, `<model>-peer-health` for the entry route's health check, and a retry policy on the health route |
| `templates/namespace.yaml` | label `aigw-ui.io/serving: "true"`, which the peer listener requires |
| `templates/llmisvc.yaml` | KServe's own path routes attach to `gateway.aiGateway.kserveRouteListener` (`peers`); `VLLM_HTTP_TIMEOUT_KEEP_ALIVE` from `llmisvc.keepAliveSeconds` (75) |
| `values.yaml` | new `peer` block; `aigatewayRoute.enabled`, the direct backend and `claudeAlias.enabled` are now `false` |

For GLM-5.3 the rendered `glm53-peer` and `glm53-peer-health` have the
same spec as the live objects.

**Gateway images**: `gitops/app-of-apps/operators/envoy-ai/values.yaml`
now says `v1.2.0-patched.2` for the controller and the extproc, with the
digests of the builds that were tested.

**Judge hook** (`charts/qwen36-judge/hook/`): the endpoint is the plain
`/v1/chat/completions`, and an `api_key` setting sends a tenant key.

**Not in this repo**, so not changed here:

- The GLM-5.3 chart that is deployed is the `bundled` branch. It already
  has the peer route and the health route. Port to it: the retry policy
  on the health route, the keep-alive, the KServe route listener
  (`http` becomes `peers`), and the three switches turned off.
- The Argo CD app `glm53-anthropic-alias`: remove it.
- The policy `glm53-b200-kserve-route-internal` and the Secret
  `glm53-internal-key`: once KServe's route is on the peer listener,
  nothing can use that key from outside. Find who uses it first.
- aigw-ui: the upgrade and the two models' entry routes are done in the
  hub.
- `charts/generic-model` still renders the old direct route by default.
  Nothing deploys it.

## What clients notice

- **Nothing**, if they call `/v1/chat/completions` or
  `/anthropic/v1/messages` with a tenant key and `glm-5.3`,
  `Qwen3.8-27B-FP8` or `judge`.
- **Quota applies** on every one of these calls. On the routes in the
  table above some calls were not counted.
- **No longer served on the VIP**: the path form
  (`/llm-<namespace>/<name>/v1/...`), the `publishers/...` model names,
  model names that start with `claude-`, and the internal key.
- **`/anthropic/v1/messages/count_tokens` answers 422.** The gateway has
  no translation for it yet. Claude Code worked without it in the test
  below.
- **Claude Code** must be told the model names: `ANTHROPIC_MODEL`, and
  `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
  `ANTHROPIC_DEFAULT_OPUS_MODEL`. Without the haiku one its background
  calls still go out under a `claude-haiku-...` name.
- **The judge hook** needs the new endpoint and a tenant key in
  `~/.claude/judge.json`. The hook in this repo sent no key, which the
  listener's key check refuses.

## Order on the cluster

Steps 1 and 2 do not depend on the rest and fix the 503 storm (see the
last section). Steps 4 to 6 belong in one maintenance window.

**0. Look first.** In the gateway's access log, count the requests

- whose model name starts with `claude-`,
- whose path starts with `/llm-` or `/publishers/`,
- that use `glm53-internal-key`.

Each one is a client that has to change before step 6.

**1. aigw-ui at commit `5b9c089` or later, then sync.**
Check: `BackendTrafficPolicy fleet-glm-5-3` shows `panicThreshold: 1` and
a health check `interval: 3s`. No model restarts.
Way back: the previous aigw-ui image.

**2. The health-route retry for GLM-5.3**, the only model with an entry
route today. Add the `BackendTrafficPolicy` from `templates/peer.yaml` to
the `bundled` branch and sync. No model restarts. Qwen3.8 and the judge
get theirs in step 4, together with their health routes.
Check: `BackendTrafficPolicy glm53-peer-health` exists and is accepted.

**3. Gateway `v1.2.0-patched.2`.** Mirror the two images, sync the
`envoy-ai` app, then restart Envoy Gateway and the proxies. Requests that
are running on a proxy are cut after its drain time.
Check: the controller Deployment and the proxies' `ai-gateway-extproc`
container show `patched.2`. Then send one `/anthropic/v1/messages`
request for `glm-5.3` **without** an `anthropic-version` header: it does
not match the alias route, so it goes through the entry route, and the
answer must contain a `thinking` block. This check follows from the
alias route's match; it was not tried.
Way back: the `patched.1` tags and the same restarts.

**4. Peer routes for Qwen3.8 and the judge, with the old routes still
on.** Sync the two charts with these site values, which hold back
everything a client could notice:

```yaml
aigatewayRoute:
  enabled: true
  claudeAlias:
    enabled: true        # qwen38 only
anthropicBackend:        # openaiBackend in the judge chart
  enabled: true
gateway:
  aiGateway:
    kserveRouteListener: ""
llmisvc:
  keepAliveSeconds: 0    # leave out to take the keep-alive now; it restarts the pods
```

Check: `qwen38-peer`, `qwen36-judge-peer` and the two health routes are
accepted on the `peers` listener.

**5. Turn on the entry route for Qwen3.8 and the judge in aigw-ui.**
The hub writes `fleet-<model>` and moves the quota to it; its own message
says the counters restart once.
Until step 6 the chart's older route still wins for the same model name,
so requests in between are probably not counted. Keep the gap short.

**6. Remove the old routes.** Delete the site values from step 4, for
GLM-5.3 turn the same three switches off on the `bundled` branch, and
remove the `glm53-anthropic-alias` app.
Check:

- `oc get httproute -A` shows on listener `http` only routes written
  by aigw-ui: `fleet-*`, and `fleetbe-*` for a model that serves a spent
  budget as best-effort.
- For each model, one request on `/v1/chat/completions` and one on
  `/anthropic/v1/messages` with a tenant key is answered, and the
  Anthropic one shows thinking for a thinking model.
- The tenant's usage in aigw-ui rises.
- aigw-ui's self-test passes.

Way back: put the site values from step 4 back. With every switch set
back the three charts render exactly what they rendered before this
change.

**7. Keep-alive 75 s**, if it was held back: remove
`llmisvc.keepAliveSeconds: 0` at the next planned restart. GLM-5.3
restarts one node at a time.

## What was tested

On a lab with the same gateway (v1.2.0), Envoy Gateway (v1.9.2) and
KServe (v0.21.0-rc1), with small CPU models and the newer model chart
that has the same route shape:

- **The `patched.2` images** (the digests in the values file). Through
  entry route, peer listener, scheduler and vLLM, a thinking model's
  answers on `/anthropic/v1/messages` contained thinking: plain,
  streamed, with a tool call, and on the follow-up turn. Before the
  upgrade the same requests returned no thinking.
- **Claude Code 2.1.286** against that gateway: a session with thinking,
  a `Read` tool call and the final answer completed. It made no
  `count_tokens` call.
- **KServe's route on the peer listener**: `sectionName: peers` in the
  LLMInferenceService gave a KServe route on that listener only.
- **The 503 storm**, see below.

On this repo:

- `helm lint` and `helm template` for the three charts. By default no
  route is on the client listener. With every switch set back the
  render equals the render before the change.
- The nine new objects (three per chart) pass a server-side dry run on
  the lab's API server, which has the same CRD versions.
- The judge hook against a local stand-in for the gateway: the key is
  sent, and a missing key, a wrong key and an unreachable gateway all
  end in "ask".

Not tested:

- Anything on the real cluster, and GLM-5.3 itself.
- These three charts installed on a cluster.
- A real tenant key and its quota counter on the new path, and the hub
  moving a quota from a direct backend to an entry route (step 5).
- Whether changing the KServe route's listener restarts the model pods.
  It is a router setting and should not; try it on the judge first.

## The 503 storm

A benchmark soak lost most of its requests to instant
`503 no healthy upstream`. The cause is a chain, and every link is in the
snapshot:

1. vLLM closes an idle HTTP connection after 5 seconds, and no model
   sets another value.
2. The entry route's health check runs every 5 seconds through the peer
   listener, and the health route has no retry.
3. A check that meets a connection being closed is answered 503. Envoy
   takes an endpoint out on one answer with a wrong status;
   `unhealthyThreshold` does not apply to that case.
4. The entry route has one endpoint and `panicThreshold: 0`, so every
   request is refused until two checks pass, about 10 seconds later.

Reproduced on the lab with those settings, 4-minute soaks of about 530
requests on an idle cluster:

| Setup | 503s | Failed health checks |
|---|---|---|
| The snapshot's settings | 93 of 533 | 4 |
| Only `panicThreshold: 1` | 0 of 530 | 6, requests still served |
| Only the retry on the health route | 0 of 531 | 0 (8 tried again) |
| Only keep-alive 75 s | 0 of 531 | 0 |

Step 1 gives the first fix, step 2 the second, and the keep-alive is the
cause itself. After steps 1 and 2, run the soak again.

## Open

- `count_tokens` on the entry path needs its own gateway patch and a new
  image tag. A count should report no usage, or counting uses up quota.
- Who uses `glm53-internal-key`.
- A quota on a model served from two or more sites needs gateway patch
  0001, which both patched builds contain.
