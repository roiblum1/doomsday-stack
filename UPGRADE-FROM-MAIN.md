# Upgrade from `main`: what the branch `llm-model-flow-control` changes, and how to apply it

This file is for the agent that works on the real repositories. It lists every change
that the export's branch `llm-model-flow-control` (commit `e942053`) makes on top of the
export's `main` (`d47d8c5`, pull request 3, 2026-10-13), and says, for each one, which
real repository it belongs to, the exact code, what must not change, how to check it,
and what it does to the running system.

Read sections 1 and 2 first. Apply section 3 one part at a time, one commit per part.

---

## 1. Rules for applying this file

1. **The export is sanitized. Do not copy its placeholders.** Wherever the code below
   shows one of these, use the real value your repository already has, and never write the
   placeholder into a real file:

   | Placeholder in this file | What it stands for |
   |---|---|
   | `host.example.internal`, `example.internal` | any real hostname (Redis, S3, peers, routes) |
   | `192.0.2.N` (any `192.0.2.x` address or prefix) | any real IP address, subnet or gateway |
   | `gpu-node-x` | a real node hostname (the export uses it for every GPU node) |
   | `registry-internal/...` | the real mirror registry path |
   | `cluster-gpu-test`, `cluster-llm-prep`, `cluster-mce-prod`, `cluster-mce-prep`, `site-a` | the real cluster, MCE and site directory names |
   | `REDACTED`, `REDACTED-B64`, ... | sanitizer output; never a value to copy |

2. **Apply by meaning, not by blind patch.** The export's chart copies are not identical
   to the real chart repositories. The real `glm53` chart's `main` in particular is newer
   than the export's copy. Find the same place in the real file and make the same change.
   Where the real file already has the change, skip it and say so in your report.

3. **Each chart is its own repository.** The export keeps the charts under `charts/`, but
   each one is a separate git repository, and the values repository (`popai`) is
   `gitops/app-of-apps/` here:

   | Export path | Real repository | Branch the Argo CD app deploys |
   |---|---|---|
   | `charts/llm-model` | the repository that holds the `llm-model` chart (lab charts) | per its app |
   | `charts/glm53-bundled` | `popai/helm-charts/glm53-chart.git` | `main` |
   | `charts/qwen38-bundled` | `popai/helm-charts/qwen38-chart.git` | per `operators/qwen38/qwen38.yaml` |
   | `charts/envoy-ai-gateway` | `popai/helm-charts/envoy-ai-chart.git` | per `operators/envoy-ai/envoy-ai.yaml` |
   | `charts/envoy-gateway` | `popai/helm-charts/envoy-gateway-chart.git` | per `operators/envoy-gateway/envoy-gateway.yaml` |
   | `charts/platform/nmstate-rdma` | `popai/helm-charts/nmstate-rdma-chart.git` | `main` |
   | `charts/generic-model` | deployed nowhere | none |
   | `gitops/app-of-apps/` | the `popai` values repository | none (read by the ApplicationSets) |

   `targetRevision` values are branch names, so **a push to a chart repository's deployed
   branch changes what Argo CD wants to run.** Push to a working branch first if the owner
   wants to review, and push to the deployed branch only when the owner says so.

4. **Check every chart change with `helm lint` and `helm template`**, using the GitOps
   value layers. Template a chart like this:
   `helm template x <chart> -f operators/<op>/values.yaml -f sites/.../<cluster>/<op>/values.yaml`.
   For each part below, compare the render with the old one (`diff`) and confirm the diff
   holds only what the part says.

5. **Do not sync Argo CD apps and do not run `kubectl`/`oc` changes** unless the owner
   asks. No model app syncs by itself; the owner syncs by hand. Report what is in git
   separately from what is running.

6. **Lists replace, maps merge** in the value layers. If you override `llmisvc.args`,
   restate the whole list.

---

## 2. Summary

| # | Part | Repository | Changes the running system when synced? | Already on the real platform? |
|---|---|---|---|---|
| A | `llm-model` chart 0.2.0: flow control counts per endpoint, waits 300 s, serves tenants in turn | llm-model chart | Only for releases with `model.flowControl.enabled=true` (scheduler restarts) | No |
| B1 | glm53: opt-in `llmisvc.flowControl` (off) | glm53-chart | No (off renders the same) | No |
| B2 | glm53: vLLM `--enable-prompt-tokens-details`, `--enable-force-include-usage` | glm53-chart | **Yes: GLM pods restart** | The live service had them on 2026-10-12; check the real chart |
| B3 | glm53: `active-request-scorer` `maxBusyScore: 0.5` | glm53-chart (or KServe preset) | Scheduler restarts | **The owner reports it is done (2026-10-14).** Check, then skip |
| B4 | glm53 app deploys `main` instead of `bundled` | popai values repo | Yes (already happened) | **Done on 2026-10-13.** Check, then skip |
| C | qwen38 chart 0.2.7: opt-in `llmisvc.flowControl` (off) | qwen38-chart | Chart label only | No |
| D | envoy-ai chart: client listener removes `x-aigw-*` by prefix; opt-in GatewayConfig (off) | envoy-ai-chart | Yes: the ClientTrafficPolicy changes (no restart) | No |
| E | Envoy Gateway global rate limiting for aigw-ui | popai values repo (+ comments in the envoy-gateway chart) | **Yes: Envoy Gateway restarts and starts `envoy-ratelimit`** | No |
| F | generic-model examples get the two billing flags | none (deployed nowhere) | No | n/a |
| G | nmstate-rdma chart: optional LACP bond per NIC entry | nmstate-rdma-chart | No (entries without `bond` render the same) | No |
| H | H200 RoCE cluster: each card's two 100G ports as one LACP bond; two servers instead of four | popai values repo | **Yes: RoCE rails go down and come back on the bonds; needs switch work first** | No |

Suggested order: A, C, B1–B2, D, F, G (chart changes, all off or harmless by default),
then E and H, which change running infrastructure and need the owner.

---

## 3. The changes

### A. `llm-model` chart 0.2.0: flow control that takes effect

**Why.** With flow control on, priority classes and tenant turns could not take effect on
a real pool:
- `maxConcurrency: 64` was meant per replica, but the scheduler's `concurrency-detector`
  counts it **per endpoint**, which is one per InferencePool `targetPort`, so one per
  data-parallel rank. On 16 ranks it let about 1,024 requests through before it held any
  back.
- `requestTTL: 60s` was shorter than waits already seen on the lab (45–48 s on one CPU
  replica).
- With no fairness policy, the scheduler serves the oldest request first whatever its
  tenant, so one tenant's backlog holds up the others. aigw-ui warns about this on every
  sync.

All of this was read against llm-d router v0.11.0, which the scheduler runs since
2026-10-14.

**A.1 `Chart.yaml`:** `version: 0.1.0` → `version: 0.2.0`.

**A.2 `templates/_helpers.tpl`:** inside the validation `define` (the one that holds the
`internalKey` check), after the `internalKey` check's `{{- end -}}`, add:

```yaml
{{- if not (has (.Values.model.flowControl.fairnessPolicy | default "") (list "" "round-robin-fairness-policy")) -}}
{{- fail "model.flowControl.fairnessPolicy must be empty or round-robin-fairness-policy" -}}
{{- end -}}
```

**A.3 `templates/llminferenceservice.yaml`:** in the scheduler's inline config.

In `plugins`, replace the `concurrency-detector` entry with this:

```yaml
          {{- if $fc.enabled }}
          - type: concurrency-detector
            parameters:
              maxConcurrency: {{ required "model.flowControl.maxConcurrency is required with flowControl.enabled: requests in flight per endpoint (InferencePool targetPort / DP rank), not per pod" $fc.maxConcurrency }}
          {{- with $fc.fairnessPolicy }}
          - type: {{ . }}
          - type: fcfs-ordering-policy
          {{- end }}
          {{- end }}
```

In the `flowControl:` section, after `defaultRequestTTL`, and inside the negative band:

```yaml
            defaultRequestTTL: {{ $fc.requestTTL }}
            {{- with $fc.fairnessPolicy }}
            defaultPriorityBand:
              fairnessPolicyRef: {{ . }}
              orderingPolicyRef: fcfs-ordering-policy
            {{- end }}
            {{- with $fc.negativeBandMaxRequests }}
            defaultNegativePriorityBand:
              maxRequests: {{ . | quote }}
              {{- /* A negative band that is set but names no policy runs
                     the scheduler's default (oldest first), not
                     defaultPriorityBand's: so llm-d router v0.11.0's config
                     loader resolves it. Not tested on the lab. */}}
              {{- with $fc.fairnessPolicy }}
              fairnessPolicyRef: {{ . }}
              orderingPolicyRef: fcfs-ordering-policy
              {{- end }}
            {{- end }}
            enableEviction: {{ $fc.enableEviction }}
```

**A.4 `values.yaml`:** under `model.flowControl`, replace `maxConcurrency` and `requestTTL`
and add `fairnessPolicy`:

```yaml
  # The settings below read the same in llm-d router v0.11.0.
  flowControl:
    enabled: false
    # Requests in flight per endpoint before the scheduler holds any back.
    # An endpoint is each port of the model's InferencePool (targetPorts),
    # so one per data-parallel rank: a pod of 8 ranks is 8 endpoints, not 1.
    # Never above each rank's --max-num-seqs: above it the queue is in vLLM,
    # first come first served, and neither classes nor turns reach it.
    # Size it from aigw-ui's capacity measurement: the most in flight one
    # instance takes within the latency targets, divided by the instance's
    # endpoints. 32 on a pod of 16 rank endpoints is 2.
    # Required with enabled=true. Left out of the scheduler config it would
    # be 100 per endpoint.
    maxConcurrency: null
    # How long a request may wait for a free slot before it gets 429. Keep
    # below route.timeout (600s). 0s means no limit: the client's own
    # timeout ends the wait. 300s was tested on the lab on 2026-10-17. A
    # short TTL sends best-effort work to the next site sooner, but standard
    # requests that wait get 429 too, and the entry does not retry those. To
    # refuse best-effort work at once instead of letting it wait, set
    # negativeBandMaxRequests.
    requestTTL: 300s
    # How the scheduler picks the next request of a class.
    # round-robin-fairness-policy: each tenant is queued on its own (the
    # header x-llm-d-inference-fairness-id, which aigw-ui sets from the
    # token) and the tenants are served in turn, so one tenant's backlog
    # does not hold up the others. Empty leaves the scheduler's default,
    # oldest request first whatever its tenant, and aigw-ui then warns on
    # every sync of a best-effort model's cluster.
    fairnessPolicy: round-robin-fairness-policy
```

Keep `negativeBandMaxRequests` and `enableEviction` as they are.

**A.5 README.** Add rows for `maxConcurrency` (per endpoint), `requestTTL` (300s) and
`fairnessPolicy`, a "Tenants in turn" section and this "Upgrading to 0.2.0" note:
- A release with `model.flowControl.enabled=true` must now set `maxConcurrency`, or the
  render fails.
- On such a release the new defaults (300s, round robin) rewrite the scheduler config,
  which restarts the scheduler. Set `requestTTL: 60s` and `fairnessPolicy: ""` to keep the
  old config.
- aigw-ui's spec hash covers the scheduler config, so it marks the model's capacity
  measurement stale. Measure again.
- With flow control off the chart renders exactly as 0.1.0.

**Lab result (2026-10-17, one CPU replica, `maxConcurrency: 2`):** one tenant sent one
request while another tenant had six waiting. With the default policy it waited 44.1 s and
28.0 s (two runs), behind the other tenant's six. With round robin and a 300s TTL it waited
25.9 s and 14.7 s, served first from the queue. Best-effort still ranked below regular
tenants.

**Check.**
- With flow control off, the render is byte-identical to before.
- With `--set model.flowControl.enabled=true --set model.flowControl.maxConcurrency=2`,
  the render has the concurrency detector, both policies and `defaultPriorityBand`.
- Adding `--set model.flowControl.negativeBandMaxRequests=4` adds the policy names to
  the negative band.
- The render fails without `maxConcurrency`, and with `fairnessPolicy=foo`.

---

### B. glm53 chart (`glm53-chart.git`, branch `main`)

**Do not bump the chart `version`.** Its pull Jobs carry `helm.sh/chart` in their
immutable pod template, and the glm53 app has no Job `ignoreDifferences`, so a version bump
fails the sync.

#### B1. Opt-in flow control, off by default

**Why.** The same settings as part A, for the GLM pool. The chart already writes its own
scheduler config (`inflight-load-producer`, `active-request-scorer`,
`token-load-scorer`, prefix scoring), so flow control is **added to** that config, not
copied over it.

**`templates/_helpers.tpl`:** append:

```yaml
{{/* llmisvc.scheduler with flow control added (llmisvc.flowControl.enabled).
     The inline EndpointPickerConfig keeps its plugins and profile and gets
     the flowControl feature gate, the concurrency-detector, the fairness and
     ordering policies and a flowControl section. Same as in qwen38-bundled. */}}
{{- define "glm53.schedulerWithFlowControl" -}}
{{- $fc := .Values.llmisvc.flowControl -}}
{{- $sched := deepCopy .Values.llmisvc.scheduler -}}
{{- $inline := get (get $sched "config" | default (dict)) "inline" | required "llmisvc.flowControl.enabled needs llmisvc.scheduler.config.inline" -}}
{{- $gates := get $inline "featureGates" | default (list) -}}
{{- if not (has "flowControl" $gates) -}}
{{- $gates = append $gates "flowControl" -}}
{{- end -}}
{{- $max := required "llmisvc.flowControl.maxConcurrency is required with flowControl.enabled: requests in flight per endpoint (InferencePool targetPort / DP rank), not per pod" $fc.maxConcurrency -}}
{{- $plugins := concat (get $inline "plugins" | default (list)) (list (dict "type" "concurrency-detector" "parameters" (dict "maxConcurrency" $max))) -}}
{{- $band := dict -}}
{{- with $fc.fairnessPolicy -}}
{{- $plugins = concat $plugins (list (dict "type" .) (dict "type" "fcfs-ordering-policy")) -}}
{{- $band = dict "fairnessPolicyRef" . "orderingPolicyRef" "fcfs-ordering-policy" -}}
{{- end -}}
{{- $flow := dict "saturationDetector" (dict "pluginRef" "concurrency-detector") "defaultRequestTTL" $fc.requestTTL "enableEviction" $fc.enableEviction -}}
{{- with $band -}}
{{- $_ := set $flow "defaultPriorityBand" . -}}
{{- end -}}
{{- with $fc.negativeBandMaxRequests -}}
{{- /* A negative band that is set but names no policy runs the scheduler's
       default (oldest first), not defaultPriorityBand's: so llm-d router
       v0.11.0's config loader resolves it. Not tested on a cluster. */ -}}
{{- $_ := set $flow "defaultNegativePriorityBand" (merge (dict "maxRequests" (toString .)) $band) -}}
{{- end -}}
{{- $_ := set $inline "featureGates" $gates -}}
{{- $_ := set $inline "plugins" $plugins -}}
{{- $_ := set $inline "flowControl" $flow -}}
{{- toYaml $sched -}}
{{- end -}}
```

**`templates/llmisvc.yaml`:** find the line `{{- with .Values.llmisvc.scheduler }}` that
opens the `scheduler:` block, and replace that one line with:

```yaml
    {{- $fc := .Values.llmisvc.flowControl | default (dict) }}
    {{- if not (has ($fc.fairnessPolicy | default "") (list "" "round-robin-fairness-policy")) }}
    {{- fail "llmisvc.flowControl.fairnessPolicy must be empty or round-robin-fairness-policy" }}
    {{- end }}
    {{- $sched := .Values.llmisvc.scheduler }}
    {{- if $fc.enabled }}
    {{- $sched = include "glm53.schedulerWithFlowControl" . | fromYaml }}
    {{- end }}
    {{- with $sched }}
```

The rest of the block stays as it is: it already renders `scheduler:` from `.`.

**`values.yaml`:** under `llmisvc:`, directly after the `scheduler:` block ends (after
its `schedulingProfiles` / `max-score-picker`), at the same indent as `scheduler:`:

```yaml
  # --- Flow control in the scheduler (off) -------------------------------------
  # With enabled=true the template adds to scheduler.config.inline above the
  # flowControl feature gate, the concurrency-detector, the fairness and
  # ordering policies and a flowControl section; the scoring profile stays as
  # it is. Requests then wait in the scheduler when the endpoints are full
  # and are released by class (InferenceObjective priority; aigw-ui's
  # best-effort is -1) and, within a class, tenant by tenant. Off, the render
  # is unchanged. Needs a gateway with agent-router#2595 (patch 0003 of the
  # v1.2.0-patched images). The same settings as charts/llm-model 0.2.0,
  # read against llm-d router v0.11.0; not tested on this model.
  flowControl:
    enabled: false
    # Requests in flight per endpoint before the scheduler holds any back.
    # An endpoint is one rank port (targetPorts above): 8 per pod, 16 in the
    # pool at replicas 2. Not above each rank's --max-num-seqs (64, below):
    # above it the queue is in vLLM, first come first served, and neither
    # classes nor turns reach it. Size it from aigw-ui's capacity
    # measurement: the most in flight one pod takes within the latency
    # targets, divided by 8. Required with enabled=true; left out of the
    # scheduler config it would be 100 per rank.
    maxConcurrency: null
    # How long a request may wait in the scheduler before it gets 429. 0s
    # means no limit: the client's own timeout ends the wait. 300s was
    # tested on the lab on 2026-10-17. A short TTL sends best-effort work to
    # the next site sooner, but standard requests that wait get 429 too, and
    # the entry does not retry those. While the pool has no ready endpoint
    # the same limit applies (noEndpointRequestTTL follows it).
    requestTTL: 300s
    # round-robin-fairness-policy: each tenant (x-llm-d-inference-fairness-id,
    # which aigw-ui sets from the token) is queued on its own and the tenants
    # are served in turn, in every class. Empty leaves the scheduler's
    # default, oldest request first whatever its tenant, and aigw-ui then
    # warns on every sync of a cluster that serves a best-effort model.
    fairnessPolicy: round-robin-fairness-policy
    # Most requests below priority 0 (batch, aigw-ui's best-effort) that may
    # wait at once; above it they get 429 at once. 0 keeps the scheduler's
    # default (5000).
    negativeBandMaxRequests: 0
    # DO NOT flip without a test: true cancels running best-effort answers
    # when standard requests wait.
    enableEviction: false
```

If the real chart's `--max-num-seqs` or rank count differs from 64 and 8, correct the
numbers in the comment.

**README:** a short section saying what `llmisvc.flowControl.enabled=true` adds, that
`maxConcurrency` is per rank port, that it needs the gateway patch 0003
(agent-router#2595), and that turning it on restarts the scheduler and makes aigw-ui mark
the capacity measurement stale.

**Check.**
- With flow control off, the render is byte-identical to before.
- With `--set llmisvc.flowControl.enabled=true --set llmisvc.flowControl.maxConcurrency=4`,
  the inline config keeps every existing plugin and the scoring profile, and gains:
  - `featureGates: [flowControl]`
  - `concurrency-detector` (`maxConcurrency: 4`)
  - `round-robin-fairness-policy` and `fcfs-ordering-policy`
  - a `flowControl` section
- The render fails without `maxConcurrency`, and with `fairnessPolicy=foo`.

#### B2. vLLM billing flags

**Why.** Cached-token prices and streamed token counts (gateway billing, aigw-ui's token
counts) need vLLM to report cached prompt tokens and to put usage on every streamed answer.
The live service had both flags (snapshot of 2026-10-12); the export's chart copy did not.

**`values.yaml`:** in `llmisvc.args`, after `--enable-prefix-caching`, add the two flags
below, unless the real chart already has both:

```yaml
    # Gateway billing and aigw-ui's token counts: report cached prompt
    # tokens, so a price can charge them less, and put usage on every
    # streamed answer, so streamed answers are counted.
    - --enable-prompt-tokens-details
    - --enable-force-include-usage
```

**Effect:** a changed arg list restarts the GLM pods (`maxSurge: 0`: one pod at a time,
capacity drops while it starts). Sync only when the owner says so.

#### B3. `maxBusyScore: 0.5` on `active-request-scorer` (probably already done)

The owner reported on 2026-10-14 that this is set, together with llm-d router v0.11.0, in
KServe's scheduler preset (`kserve-config-llm-scheduler`). Check where the running GLM
scheduler config comes from:
- If it is set there or in the chart: skip this part.
- If it is set nowhere: add it to the chart's inline scheduler config. Change the plugin
  entry `- type: active-request-scorer` to:

```yaml
          # maxBusyScore 0.5. With the default, 1.0, a busy rank is scored
          # against the BUSIEST rank only -- (max - count) / max -- so one hot
          # rank made a rank that holds the prefix keep winning over an idle
          # one (benchmark run 3: repeated prompts slower than fresh ones).
          # With 0.5 an idle rank always wins: the best a busy holder reaches
          # is 3*0.5 + 1 + 1 = 3.5, an idle rank scores 3 + ~1. The condition is
          #   active weight * maxBusyScore + prefix weight < active weight
          # so anything below 0.66 at the weights 3 and 1 of the profile.
          # Not 0: once every one of the 16 ranks has a request, all of them
          # would score 0 and this weight-3 scorer would say nothing.
          # requestTimeout is ignored since llm-d-router v0.10.0 and
          # idleThreshold 0 is the default, so neither is set.
          - type: active-request-scorer
            parameters:
              maxBusyScore: 0.5
```

The reasoning holds only for weights `active-request-scorer: 3`, `prefix-cache-scorer: 1`
and `token-load-scorer: 1`. If the real weights differ, recompute the condition before you
change anything.

#### B4. glm53 app on `main` (already done)

In the values repository, `operators/glm53/glm53.yaml` has `targetRevision: main`, with
this comment in place of the old "pinned to bundled" one:

```yaml
# `main` since 2026-10-13: the tuned bundle (CR name glm53-b200 serving
# glm-5.3, runtimeClassName, the DP8-tuned EPP profile, the 8-rank-port pool,
# LMCache, the node-prep storage layer, maxSurge 0) was moved to `main` and
# is deployed from there. Until then this app was pinned to the `bundled`
# branch (fdd21bd + the vLLM billing flags, 2026-10-12), because `main`
# carried the generic llm-model chart, which cannot express this deployment.
targetRevision: main
```

The owner made this change on 2026-10-13. Check it, then skip; at most, update the
comment.

---

### C. qwen38 chart 0.2.7 (`qwen38-chart.git`): opt-in flow control, off

The same as B1, with these differences:
- `Chart.yaml`: `version: 0.2.6` → `0.2.7`. A bump is safe here: the qwen38 app ignores
  the pull Job's pod labels (`ignoreDifferences` with `RespectIgnoreDifferences=true` in
  `operators/qwen38/qwen38.yaml`). Check that this is still true before you bump.
- The helper is named `qwen38.schedulerWithFlowControl`, its comment ends
  "Same as in glm53-bundled", and `templates/llmisvc.yaml` includes
  `"qwen38.schedulerWithFlowControl"`.
- The `maxConcurrency` comment in `values.yaml` reads:

```yaml
    # Requests in flight per endpoint before the scheduler holds any back.
    # An endpoint is each InferencePool targetPort; here one per pod (8000:
    # vLLM balances its DP ranks behind one API server). Not above the pod's
    # --max-num-seqs (32, below): above it the queue is in vLLM, first come
    # first served, and neither classes nor turns reach it. Size it from
    # aigw-ui's capacity measurement: the most in flight one pod takes
    # within the latency targets. Required with enabled=true; left out of
    # the scheduler config it would be 100 per endpoint.
    maxConcurrency: null
```

**Effect when synced:** with flow control off, only the chart label changes (0.2.7).

**Do not change the qwen36 judge.** It runs KServe's preset scheduler with one endpoint and
1–3 requests at a time, so there is nothing to hold back.

---

### D. envoy-ai chart (`envoy-ai-chart.git`)

#### D1. Client listener removes every `x-aigw-*` header

**Why.** aigw-ui's token check writes `x-aigw-tenant`, `x-aigw-key`, `x-aigw-client-id`,
`x-aigw-budget` and one `x-aigw-quota-<model>` per model, and its rate limit rules count by
them. Envoy 1.39 removes a client's own copy only on requests the token check runs on;
removal by prefix covers the rest, including headers of models added later. This is what
aigw-ui's security guide asks for. The peer listener keeps these headers: the serving site
counts the request by its tenant.

**`values.yaml`:** under `gateway.clientTrafficPolicy`, after the existing
`removeRequestHeaders` list (**keep that list unchanged; it is marked DO NOT REMOVE**), add:

```yaml
    # DO NOT REMOVE: every header whose name starts with one of these is
    # removed too. aigw-ui's token check writes x-aigw-tenant, x-aigw-key,
    # x-aigw-client-id, x-aigw-budget and one x-aigw-quota-<model> per model
    # (aigw-ui 0.18 to 0.24) and its rate limit rules count by them. Envoy
    # 1.39 removes a client's own copy only on requests the token check
    # runs on (aigw-ui docs/security.md, "Defense in depth"); this covers
    # the rest, the headers of models added later included. Client
    # listener only: the peer listener keeps them, since the serving site
    # counts the request by its tenant.
    removeRequestHeaderPrefixes:
      - x-aigw-
```

**`templates/gateway.yaml`:** in the ClientTrafficPolicy of the client listener, replace
the `{{- with .Values.gateway.clientTrafficPolicy.removeRequestHeaders }} headers: ...
{{- end }}` block with:

```yaml
  {{- $ctp := .Values.gateway.clientTrafficPolicy }}
  {{- if or $ctp.removeRequestHeaders $ctp.removeRequestHeaderPrefixes }}
  headers:
    earlyRequestHeaders:
      {{- with $ctp.removeRequestHeaders }}
      remove:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $ctp.removeRequestHeaderPrefixes }}
      removeOnMatch:
        {{- range . }}
        - type: Prefix
          value: {{ . }}
        {{- end }}
      {{- end }}
  {{- end }}
```

**Do not change** the header strip list, `x-llm-d-inference-fairness-id` in it, or the
peer listener's policy.

#### D2. Opt-in GatewayConfig for token counts (off)

**Why.** aigw-ui counts each tenant's input, cached and output tokens from metadata keys
that a route writes. The routes it renders already carry the keys. A GatewayConfig gives
them to every other route of the Gateway. Leave it off while every model is served behind
aigw-ui's entry route, which is the case today.

**`values.yaml`:** under `gateway:`, before the client connection buffer settings:

```yaml
  # ---- Token counts on routes aigw-ui does not touch (aigw-ui 0.30) --------
  # aigw-ui counts each tenant's input, cached and output tokens by model,
  # from metadata keys a route writes. The routes it renders and the ones it
  # marks carry the keys already. A GatewayConfig gives them to every other
  # route of this Gateway too, and the Gateway names it in the annotation
  # aigateway.envoyproxy.io/gateway-config. A route's own key of the same
  # name wins. Off is fine while every model is served on the peer listener
  # behind aigw-ui's entry route, as the model charts do: the entry route
  # carries the keys. Turn it on for a route of this cluster's own on the
  # client listener, or a tenant's page shows its requests there with no
  # tokens. The AI gateway controller then writes a hash of the config onto
  # the Gateway (aigateway.envoyproxy.io/gateway-config-hash).
  gatewayConfig:
    enabled: false
    name: envoy-ai-gateway
```

**New file `templates/gatewayconfig.yaml`:**

```yaml
{{- if and .Values.gateway.enabled .Values.gateway.gatewayConfig.enabled }}
{{- $wave := dig "syncWave" dict (.Values.argocd | default dict) }}
#
# Request costs every route of the Gateway writes, for aigw-ui's token
# counts (aigw-ui docs/deployment.md, "Token counts on every route"). The
# key names are the ones its rate limit rules read; do not rename them.
#
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: GatewayConfig
metadata:
  name: {{ .Values.gateway.gatewayConfig.name }}
  namespace: {{ include "envoy-ai-gateway-openshift.gatewayNamespace" . }}
  {{- include "envoy-ai-gateway-openshift.annotations" (dict "wave" $wave.gateway) | nindent 2 }}
  labels:
    {{- include "envoy-ai-gateway-openshift.labels" . | nindent 4 }}
spec:
  globalLLMRequestCosts:
    - metadataKey: aigw_ui_input
      type: InputToken
    - metadataKey: aigw_ui_cached
      type: CachedInputToken
    - metadataKey: aigw_ui_output
      type: OutputToken
{{- end }}
```

**`templates/gateway.yaml`:** on the `Gateway` metadata, replace the annotations include
with:

```yaml
  {{- $gwAnn := dict }}
  {{- if .Values.gateway.gatewayConfig.enabled }}
  {{- $_ := set $gwAnn "aigateway.envoyproxy.io/gateway-config" .Values.gateway.gatewayConfig.name }}
  {{- end }}
  {{- include "envoy-ai-gateway-openshift.annotations" (dict "wave" $wave.gateway "extra" $gwAnn) | nindent 2 }}
```

The `annotations` helper must merge `.extra`. In the export it already does
(`{{- with .extra }}{{- $ann = merge $ann . }}{{- end -}}`); if the real helper does not,
add that line.

**Check.** Render the chart. Note that this chart and envoy-gateway do not render as
checked in: copy the chart to a scratch directory and put the vendored `ai-gateway-helm`
under `<copy>/charts/`. Then confirm:
- The ClientTrafficPolicy has `removeOnMatch: [{type: Prefix, value: x-aigw-}]` next to
  the old `remove` list.
- With `gateway.gatewayConfig.enabled=false`, there is no GatewayConfig and no new
  annotation.
- With it `true`, both appear.

---

### E. Envoy Gateway global rate limiting (values repository + chart comments)

**Why.** aigw-ui's BackendTrafficPolicy `aigw-ui-tenant-budgets` holds each tenant's
budget across models (aigw-ui 0.22) and, from 0.30, counts each tenant's tokens
(`redis.tokenCounts`, on by default). Both are Envoy Gateway **global** rate limits.
Without `rateLimit.backend` the policy is not accepted, and nothing in it is counted or
held.

**E.1 envoy-gateway chart `values.yaml`, comments only.**
- Above `enableEnvoyPatchPolicy: true`: "Required by aigw-ui: its entry routes carry an
  EnvoyPatchPolicy (fleet-<model>-retry)."
- After it, a comment block saying:
  - global rate limiting is a site value (see E.3);
  - leave `runtimeFlags` unset for `XDSNameSchemeV2`: aigw-ui 0.29+ patches both route
    configuration names;
  - after an upgrade to Envoy Gateway 1.10, sync the cluster in aigw-ui and run its
    self-test.

**E.2 `operators/envoy-gateway/values.yaml`:** under `envoy-gateway.global.images`, add
the rate limit image. The chart default is a full mirror reference, which `imageRegistry`
would double.

```yaml
      # Envoy Gateway's own rate limit service (envoy-ratelimit), which runs
      # once a cluster turns on global rate limiting (rateLimit:, in the
      # site layer). The chart's default is a full mirror reference, which
      # imageRegistry would double. This is the build the live config named
      # and the AI gateway's quota service runs, so the mirror has it.
      ratelimit:
        image: docker.io/envoyproxy/ratelimit:0482748e
```

Check that this tag is the one the AI gateway's quota rate limit service runs in the real
cluster, and that the mirror holds it.

**E.3 Site layer `sites/<site>/<env>/mces/<mce>/<llm cluster>/envoy-gateway/values.yaml`**
(the export's `cluster-llm-prep`). Before writing it:
- **Redis URL:** use the same Redis host and port as the envoy-ai site layer's quota
  Redis. `host.example.internal:443` below is a placeholder.
- **Secret:** `envoy-ai-quota-redis-client` (keys `password`, `ca.crt`) must exist in
  `envoy-gateway-system`. It is made by hand; check it with the owner before the sync.

```yaml
envoy-gateway:
  config:
    envoyGateway:
      rateLimit:
        backend:
          type: Redis
          redis:
            url: host.example.internal:443      # PLACEHOLDER: the envoy-ai quota Redis
        # How long a request waits for the rate limit service before it is
        # let through uncounted. Envoy Gateway's default, 20ms, is shorter
        # than a round trip to a Redis across the network, so every request
        # would pass unheld. The same as the AI gateway's
        # quotaRateLimitTimeout (envoy-ai site layer), so both fail open alike.
        timeout: 1s
      provider:
        kubernetes:
          rateLimitDeployment:
            container:
              env:
                - name: REDIS_TLS
                  value: "true"
                - name: REDIS_TLS_CACERT
                  value: /etc/envoy-ratelimit-redis/ca.crt
                - name: REDIS_AUTH
                  valueFrom:
                    secretKeyRef:
                      name: envoy-ai-quota-redis-client
                      key: password
              volumeMounts:
                - name: redis-ca
                  mountPath: /etc/envoy-ratelimit-redis
                  readOnly: true
            pod:
              volumes:
                - name: redis-ca
                  secret:
                    secretName: envoy-ai-quota-redis-client
                    items:
                      - key: ca.crt
                        path: ca.crt
  deployment:
    pod:
      annotations:
        # Envoy Gateway 1.9 reloads its configuration file when the
        # ConfigMap changes, once the kubelet has updated the file (up to
        # about a minute); a file that fails validation is logged and the
        # old configuration stays. Changing this value with the rateLimit
        # block above makes the sync restart the controller, so a bad
        # configuration shows as a pod that does not start.
        config-revision/rate-limit: "1"
```

Why TLS, the CA and the password go through env and volumes: Envoy Gateway 1.9's
`rateLimit.backend.redis.tls` takes a client certificate and cannot mount only a CA. So
they are passed the same way the AI gateway's rate limit service gets them (`REDIS_TLS`,
`REDIS_TLS_CACERT`, `REDIS_AUTH`).

**Effect when synced:** the Envoy Gateway controller restarts, and a new Deployment
`envoy-ratelimit` starts in `envoy-gateway-system`. It counts in the same Redis as the AI
gateway's `envoy-ai-gateway-ratelimit` and aigw-ui. If Redis cannot be reached, requests
pass uncounted after 1 s (fail open).

**After the sync, check:**
- `envoy-ratelimit` is Ready.
- `BackendTrafficPolicy aigw-ui-tenant-budgets` is `Accepted`.
- aigw-ui's self-test passes "The tenant's requests and tokens are counted by model" (and,
  with a budget, "A budget across models is counted and refuses").

---

### F. generic-model examples (deployed nowhere)

In `examples/glm53.values.yaml`, `examples/qwen38.values.yaml` and
`examples/qwen36-judge.values.yaml`, after `--enable-prefix-caching`, add:

```yaml
    # Gateway billing and aigw-ui's token counts: cached prompt tokens and
    # usage on streamed answers (as glm53-bundled, qwen38-bundled, qwen36-judge).
    - --enable-prompt-tokens-details
    - --enable-force-include-usage
```

Nothing deploys this chart. This is optional; it keeps the examples in line with the
model charts.

---

### G. nmstate-rdma chart (`nmstate-rdma-chart.git`): optional LACP bond per NIC entry

**Why.** The H200 RoCE servers have eight dual-port ConnectX-6 Dx cards with both ports
cabled. To send on both 100G ports of a card as one RDMA device, the two ports must be one
bond. This is RoCE LAG, from NVIDIA DOCA "RDMA over Converged Ethernet":
- It needs a dual-port card, and both ports of that card, and only those two, in one bond.
- The bond must be mode 1 (active-backup), 2 (balance-xor) or 4 (802.3ad).
- The driver then replaces the two RDMA devices with one device, `mlx5_bond_N`, that uses
  both ports.

OpenShift's NMState supports `active-backup`, `balance-xor` and `802.3ad` bonds.

**Chart version:** this export keeps `4.22.0`. Bump it if your chart repository bumps on
template changes.

**`templates/nncp-roce.yaml`:**

1. At the end of the header comment, before `*/}}`, add:

```
RoCE LAG: when a NIC entry has `bond`, its `name` is a bond over bond.ports (both ports of
one dual-port card, and only them: that is what makes the mlx5 driver merge the card into
one RDMA device, mlx5_bond_N). The IP, route-rule and routes then sit on the bond; the
ports carry only the MTU.
```

2. After `{{- if eq .Values.mode "roce" }}`, add:

```yaml
{{- $bondDefaults := .Values.roce.bond | default dict }}
```

3. Under `desiredState.interfaces:`, replace the single ethernet interface (the `- name:
   {{ $nic.name }}` entry with `type: ethernet`, `state: up` and `mtu`, which comes before
   its `ipv4:` block) with the block below. The `ipv4:`/`ipv6:` lines that follow stay as
   they are; they now belong to the bond, or to the ethernet interface when there is no
   bond.

```yaml
      {{- if $nic.bond }}
      {{- if ne (len $nic.bond.ports) 2 }}
      {{- fail (printf "roce.nodes[%s].nics[%s].bond.ports must list exactly the two ports of one card (RoCE LAG)" $node.name $nic.name) }}
      {{- end }}
      {{- range $port := $nic.bond.ports }}
      - name: {{ $port }}
        type: ethernet
        state: up
        mtu: {{ $.Values.roce.mtu }}
        ipv4:
          enabled: false
        ipv6:
          enabled: false
      {{- end }}
      - name: {{ $nic.name }}
        type: bond
        state: up
        mtu: {{ $.Values.roce.mtu }}
        link-aggregation:
          mode: {{ $nic.bond.mode | default $bondDefaults.mode | default "802.3ad" }}
          options:
            {{- toYaml (mergeOverwrite (deepCopy ($bondDefaults.options | default (dict))) (deepCopy ($nic.bond.options | default (dict)))) | nindent 12 }}
          port:
            {{- range $port := $nic.bond.ports }}
            - {{ $port }}
            {{- end }}
      {{- else }}
      - name: {{ $nic.name }}
        type: ethernet
        state: up
        mtu: {{ $.Values.roce.mtu }}
      {{- end }}
```

The route-rule and routes code needs no change: it uses `$nic.name` as
`next-hop-interface`, which is now the bond.

**`values.yaml`:** under `roce:`, after `mtu: 9000`, add:

```yaml
  # Defaults for every NIC entry that has `bond`. 802.3ad, active-backup and balance-xor
  # are the modes both OpenShift and RoCE LAG support. layer3+4 hashes RoCEv2 on the UDP
  # source port, which differs per QP, so QPs spread over both ports; one QP stays on one
  # port (100G), so the full 200G needs NCCL_IB_QPS_PER_CONNECTION >= 2.
  bond:
    mode: 802.3ad
    options:
      miimon: "100"
      lacp_rate: fast
      xmit_hash_policy: layer3+4
```

Also add an example to the comment above `roce:`:

```
# RoCE LAG (both ports of one card as one 802.3ad bond): give the NIC entry a bond name
# and a `bond` block. The NNCP then makes the bond, puts the IP, rule and routes on it,
# and the driver exposes the card as one RDMA device (mlx5_bond_N) over both ports.
#   - name: bond-rail0
#     bond:
#       ports: [ens32f0np0, ens32f1np1]   # exactly the two ports of the same card
#       # mode / options override roce.bond below
#     ip: <host ip>/31
#     gateway: <gateway ip>
```

**Check.**
- With the current cluster values (no `bond` anywhere), the render is byte-identical to
  before. In the export: 1,830 lines, identical.
- One test entry with a `bond` renders three interfaces: two ethernet ports with no IP
  and MTU 9000, and a `type: bond` with `mode: 802.3ad`, the three options and both
  ports. The IP, rule and routes are on the bond.
- A `bond` with one port fails the render with the message above.

**Effect when synced:** none, until a cluster's values use `bond`.

---

### H. The H200 RoCE cluster: bonds, and two servers instead of four

In the export this cluster is `cluster-gpu-test` (`site-a / prod / cluster-mce-prod`).
Use its real directory in your values repository.

**Do not start H without the owner.** It takes every RoCE rail of a node down and brings
it back on the bond. It also needs switch work first.

#### H.1 Switch side (prerequisite, not in git)

For each server and each card, the leaf needs one LACP port-channel over the card's two
ports:
- mode active, LACP rate fast (to match `lacp_rate: fast`);
- MTU 9000 or more;
- PFC on priority 3 and DSCP trust on both members, as the single ports have today;
- routed, with the rail's /31 gateway moved from the single leaf port to the
  port-channel.

Without it the bond has no LACP partner and the rail carries nothing.

Ask the owner where each card's two ports go:
- **Same leaf:** a plain port-channel. Fabric A (rails 0–3 on Leaf_01) and fabric B
  (rails 4–7 on Leaf_02) stay as they are.
- **Two leaves:** the earlier cabling, before 2026-09-10, had f0 and f1 of a card on
  different leaves. Then the leaves need MLAG/vPC for the port-channel. A /31 cannot sit
  on two switches, so the gateway becomes a shared (VRR/anycast) address on a small
  subnet, and every ip/gateway in H.2 changes. **Stop and ask the owner for the new IP
  plan.**

#### H.2 `<cluster>/nmstate-rdma/values.yaml`

**Keep only the two H200 servers the cluster has.** The export kept the two entries
commented `server0` (service tag 2sb9mc4, leaf ports `Eth1/1/*`) and `server1` (dsb9mc4,
`Eth1/2/*`), and removed server2 (f5fgdb4) and server3 (7d7sdb4). That choice was an
assumption: confirm with the owner which two servers remain, and keep those.

**Convert every rail entry of the kept servers, by this rule.** For card number
`c` = 32..39, rail `r` = c − 32:

```yaml
# before
    - name: ens<c>f0np0
      ip: <real host ip>/31
      gateway: <real gateway ip>
      routes: [...]
      tableID: <200+r>
      routeRulePriority: <1000+r>
# after
    - name: bond-rail<r>
      bond:
        ports:
        - ens<c>f0np0
        - ens<c>f1np1
      ip: <real host ip>/31            # unchanged
      gateway: <real gateway ip>       # unchanged
      routes: [...]                    # unchanged
      tableID: <200+r>                 # unchanged
      routeRulePriority: <1000+r>      # unchanged
```

**Change only `name` and add `bond`.** Keep every real IP, gateway, route, table and
priority exactly as it is. In the export, the render before and after differs only in:
- the NNCP names (`roce-<node>-ens<c>f0np0` → `roce-<node>-bond-rail<r>`);
- `next-hop-interface` (port → bond);
- the added port and bond interfaces.

The checksum of all IPs, rules, tables and next hops was identical.

Before you convert, check the second port's name on a node (`ip -br link | grep ens32`).
The export assumes `ens<c>f1np1`, as the 2026-09-09 LLDP check saw it.

Replace the header comment with one that says:
- what the bond is, and why it gives up to 200G per GPU (see H.4);
- the switch prerequisite (H.1);
- the migration steps (H.3);
- that the two servers are the whole RoCE pool.

Also add, above `nodes:`:

```yaml
  # bond defaults (802.3ad, miimon 100, lacp_rate fast, xmit_hash_policy layer3+4) come
  # from the chart's roce.bond; override per bond under nics[].bond.options.
```

#### H.3 Migration, one node at a time

1. Cordon and drain the node. Its rails go down.
2. Switch: create that server's eight port-channels and move the gateways.
3. Sync nmstate-rdma. The new NNCP sets the f0/f1 ports to "no IP" and makes the bond, so
   the old address and its routes leave `ens<c>f0np0`. **kubernetes-nmstate does not undo
   the old NNCPs when they leave git** (Red Hat: deleting a policy does not change the
   node). Check on the node (`oc debug node/<n>`, then `chroot /host`):

   ```sh
   ip -4 addr show | grep -E 'ens3[2-9]f[01]np[01]'   # expect nothing: the IPs are on bond-rail*
   for t in 200 201 202 203 204 205 206 207; do ip route show table $t; done
   # every route says dev bond-rail<r>; delete any route left on ens3Xf0np0
   ip rule                                           # one "from <ip> lookup 20<r>" per rail
   cat /proc/net/bonding/bond-rail0   # 802.3ad, both ports "MII Status: up", same
                                      # "Aggregator ID", partner MAC not 00:00:00:00:00:00
   rdma link show                     # mlx5_bond_0..7 ACTIVE, netdev bond-rail<r>
   mlnx_qos -i ens32f0np0; mlnx_qos -i ens32f1np1   # trust dscp, PFC on priority 3, both ports
   ```

4. Measure: `ib_write_bw -d mlx5_bond_0 -q 4` (four QPs or more) to the other node on the
   same rail. About twice the single-port number means both links carry traffic.
5. Uncordon. Then do the next node.

Never change a bond by hand while the driver is loaded; change the values file. To
remove a bond later, first set it `state: absent` in a policy.

#### H.4 What gives 200G, and what does not

| Result | What it means | What to do |
|---|---|---|
| `ib_write_bw -q 1` about 100G, `-q 4` about 2x | Correct: one QP always uses one port | Workloads must open several QPs: `NCCL_IB_QPS_PER_CONNECTION=4` (2 or more) |
| `-q 4` still about 100G | All QPs hash to one port | Check `xmit_hash_policy` is `layer3+4` (`/proc/net/bonding/...`) and that the switch hashes on L4 too |
| Total around 200G but never more | Expected: a ConnectX-6 Dx is PCIe Gen4 x16, about 200–220 Gb/s usable | Nothing; this is the card's limit |
| Bond up, `rdma link` still shows two `mlx5_N` devices | RoCE LAG did not form | Both PFs of one card, and nothing else, must be in the bond; mode must be 1, 2 or 4 |
| Bond has no partner MAC | No LACP on the switch | H.1 |

For NCCL workloads on these nodes, set `NCCL_IB_HCA=mlx5_bond_0,...,mlx5_bond_7` (check
the names with `rdma link`) and `NCCL_IB_QPS_PER_CONNECTION` to 2 or more.

#### H.5 `<cluster>/network/values.yaml`: comments only

Nothing in the NVIDIA Network Operator config changes. Add this comment above
`fabric: roce`:

```yaml
# RoCE LAG (2026-10-19): nmstate-rdma bonds each card's two ports (bond-rail0..7) and the
# driver merges the card into one RDMA device, mlx5_bond_N. Nothing below changes for it:
#   - rdmaSharedDevicePlugin.ifNames keeps the f0np0 names. The plugin selects a PCI
#     function by its netdev name and hands out that function's RDMA devices; mlx5_bond_N
#     belongs to the card's first function (f0), and f1 has no RDMA device left.
#   - nicConfigurationTemplates.pciAddresses names each card by its f0 address; the NIC
#     Configuration Operator configures the whole card, and roceOptimized sets both ports
#     (nvconfig *_P1 and *_P2; DSCP trust and PFC on each PF).
```

Above the RDMA plugin's `ifNames:` list, add
`# f0 netdev of each card: selects that card's mlx5_bond_N (see the header).`

The f0 claim is read from the plugin's source (`pci_net_device.go`), not seen on a node.
After the first node is migrated, check it:
`ls /sys/bus/pci/devices/<f0 PCI address>/infiniband` should list `mlx5_bond_N`. Also
check that the RDMA plugin pod still reports `rdma/roce_backend` on the node
(`oc describe node`). If the device sits on f1 instead, change `ifNames` to the
`f1np1` names.

#### H.6 `<cluster>/gpu/values.yaml`: header comment only

"... and 4 new H200 RoCE nodes." → "... and 2 H200 RoCE nodes." The B300 nodes and both
driver pools stay.

---

## 4. Report back to the owner

For every part, report:
1. **Applied, skipped or already present**, with the commit and repository.
2. **Render check:** what the `diff` of old and new render showed.
3. **What syncing it would do:** which pods restart, and which services start.
4. **What you could not check** without a sync or the switches.

Do not report anything as "live" until the Argo CD app shows synced and you have checked
the running object.

---

## 5. Where these changes come from (export commits)

| Commit | Subject |
|---|---|
| `8c58ae1` | The model chart's flow control counts per endpoint, lets requests wait 300 s and serves tenants in turn (part A) |
| `707f1eb` | GLM-5.3 and Qwen3.8 can turn on the same flow control, added to their own scheduler profile (B1, C) |
| `4e445bd` | The site gives aigw-ui up to 0.32.1 what it needs: global rate limiting, x-aigw- headers removed by prefix, GLM's billing flags (B2, D, E, F) |
| `007c7b1` | Each H200 card on cluster-gpu-test sends on both 100G ports as one LACP bond (G, H) |
| `e942053` | GLM-5.3 deploys from main with maxBusyScore 0.5, and CLAUDE.md sends agents to the knowledge base (B3, B4; also the export's CLAUDE.md and `AGENT-Dissconnected.md` facts R131–R136, which change no real repository) |

Sources used for part G/H: NVIDIA DOCA 3.4 "RDMA over Converged Ethernet" (RoCE LAG);
Red Hat OpenShift "Kubernetes NMState" (bond policy, supported modes, deleted policies
leave state); nmstate.io YAML API (bond options); NVIDIA Network Operator 26.4.1 NIC
Configuration Operator "configuration details" (roceOptimized per port);
`Mellanox/k8s-rdma-shared-dev-plugin` source; NCCL environment variables
(`NCCL_IB_QPS_PER_CONNECTION`, default 1).
