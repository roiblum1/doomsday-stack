# Multi-site LLM platform: architecture review, disconnected run

> Paste below the line into the agent, opened at a directory that holds both repos as
> siblings: `doomsday-stack/` (the sanitized export of one serving site) and `aigw-ui/`
> (the hub). This file replaces `AGENT.md` for a run with no internet. The task, the
> constraints and the budget are the ones of `AGENT.md`. What is new: section 4 is
> corrected, and sections 6 to 8 hold the upstream research that a disconnected agent
> cannot do. It was written on 2026-10-13 by Claude on the connected side, from the
> upstream source at the versions this platform runs, and from tests on a lab pair
> (one hub cluster, one LLM cluster with one small CPU model).

---

## 0. Fill in before running

```
DOOMSDAY_PATH   = ./doomsday-stack
AIGW_PATH       = ./aigw-ui
BRAIN_REPO      = <<path to the team Brain repo, or "none">>
SITES           = <<one line per site: name | cluster | GPUs | models served | topology | notes>>
HUB             = <<hub cluster name; the site it is co-located with>>
INTER_SITE_RTT  = <<ms between sites>>
CLIENTS         = Claude Code (Anthropic route, header x-claude-code-session-id),
                  Open WebUI (header x-openwebui-chat-id), scripts with the OpenAI SDK,
                  <<others>>
TENANT_SCALE    = <<tenants today / in 12 months; API keys per tenant>>
TRAFFIC_SHAPE   = <<e.g. "mostly agentic 100k-context sessions; peak 20-30 concurrent users per big site">>
PAIN_TODAY      = <<the 3-5 things that hurt most, in the owner's words>>
HORIZON         = <<e.g. "12 months, +2 sites">>
REAL_STATE      = finished, the GLM branch `bundled` included (owner, 2026-10-13). Every request
                  goes through the entry route. The owner was not asked separately whether
                  that branch carries `healthRetries` and `keepAliveSeconds`: see R92
PRIORITIES      = <<the owner's order when goals conflict. A reviewer proposed:
                  Claude Code user experience > quota correctness > operability > tenant scale>>
TARGETS         = <<what "good" means, to rank findings against. A reviewer proposed these;
                  the numbers are not the owner's until confirmed:
                  a conversation stays at its site for >= 99% of its requests;
                  p90 time to first token of a warm turn <= 5 s;
                  quota error within 2% of what was used;
                  gateway overhead p99 <= 25 ms at a 1 MB body;
                  a revoked key stops working within 60 s>>
PATCH_PLAN      = not decided (owner, 2026-10-13). You recommend one: T2 in section 12
RL_ALERT        = not known to the owner (2026-10-13). You check: T3 in section 12
FLOOR_200MS     = yours to measure and to act on: T1 in section 12
```

If a field is still a placeholder when you start, do not guess it. Write the finding
for both cases, or list it in `04-OPEN-QUESTIONS.md`. Without `TARGETS` and
`PRIORITIES`, rank by the consequence for a user and say that you did.

---

## 1. Who you are and what you deliver

You are a platform architect reviewing a working multi-site LLM serving platform and
designing its next version. You do not rewrite it. You find the small number of changes
that matter, prove each one against the code and the manifests, and leave decisions the
owner can act on, with the exact objects, charts and hub code that change.

All output goes in `arch-review/` in the current directory, committed on a branch
`arch-review/<date>` in the repo that holds the directory.

1. `00-CURRENT-STATE.md`: the platform as it is, derived from YAML and Go and not from
   docs. One request traced end to end per client type (OpenAI, Anthropic, cross-site,
   best-effort), and a table of every place state lives (Postgres, Redis, per-cluster
   objects, EPP memory, vLLM KV cache, LMCache tiers).
2. `01-GAPS.md`: ranked findings. Each one: what, evidence, blast radius, how a user
   sees it, severity S1 (outage class) to S4 (polish). The main list holds at most 10
   findings, ranked by how far each is from `TARGETS`, in the order of `PRIORITIES`.
   Everything else goes in an appendix table, one line each.
3. `02-TARGET-ARCHITECTURE.md`: the target design. A Mermaid diagram, the request path,
   the control-plane loop, what runs where, one sentence per constraint of section 2 on
   how the target honors it, and the failure matrix of section 10.
4. `adr/ADR-NNN-<slug>.md`: one per decision (Context / Options with real trade-offs /
   Decision / Consequences / What to measure). 6 to 10 of them, each at most 600 words.
   An ADR with one option is not an ADR. Every ADR lists "keep as is" with its real
   merits.
5. `03-ROADMAP.md`: an ordered table. Per item: repo and files or objects touched, size
   (S/M/L), dependencies, risk, rollback, and the one metric that proves it. Phase 1
   must fit two weeks for one person.
6. `04-OPEN-QUESTIONS.md`: what you could not settle, each with the cheapest experiment
   that would settle it.
7. Draft PRs for the top 3 roadmap items that are code or chart changes: a branch or a
   patch in the right repo, at most about 400 changed lines each, that passes that
   repo's own checks. Not merged, not applied anywhere.

Done means: all seven exist, every finding and decision cites evidence, the three drafts
pass their checks locally, and the budget of section 3 was kept. Then stop and report in
at most 20 lines: the three decisions that matter most, the one thing to do first, and
what you did not get to.

---

## 2. Constraints

These are the design, not obstacles to it.

1. **No user prompt passes through code the owner wrote.** The data plane is
   off-the-shelf only: Envoy Gateway, Envoy AI Gateway (its extproc included), the llm-d
   EPP, vLLM, LMCache. `aigw-ui` is a control plane. A custom ext-proc, a Lua filter, a
   custom router, a "site picker" service or a WASM module in the request path is
   rejected at the idea stage. If nothing upstream does the job, write an upstream
   feature request in `04-OPEN-QUESTIONS.md`.
   *Reading used in this file, to confirm with the owner if an ADR depends on it:*
   configuration of an off-the-shelf component counts as configuration, including an
   `EnvoyPatchPolicy` (the hub already writes one per entry route) and EPP plugin
   settings. Envoy Gateway's load balancer type `DynamicModule` loads a shared library
   into the proxy: that is code, so it is rejected.
2. **Fully disconnected sites.** Everything is mirrored. No cloud service, no SaaS.
   Links between sites exist but are not assumed lossless or fast.
3. **Heterogeneous sites.** The same model id may run on very different hardware at two
   sites, and some sites lack some models. Capacity differs 5 to 10 times. Treat them as
   one pool without pretending they are equal.
4. **One hub, many sites.** A site keeps serving when the hub is unreachable. What
   degrades must be explicit and bounded.
5. **GitOps for charts, hub for live objects.** The hub force-applies and prunes
   everything labelled `app.kubernetes.io/managed-by: aigw-ui` every 5 minutes. The two
   never fight over an object. Respect every "DO NOT REMOVE" and every invariant in
   `doomsday-stack/CLAUDE.md`.
6. **Names are quota counter keys.** A design that renames a gateway namespace, an
   AIServiceBackend or a model says how the counters migrate.
7. **No cluster operations.** No `kubectl`, `oc`, `argocd`, `helm install` or
   `helm upgrade`. Your checks are `helm lint`, `helm template`, `go test`, `go vet`
   and reading. One exception, from the owner on 2026-10-13: the read-only commands of
   section 12, for the checks T1 and T3 and for nothing else.
8. **Sanitized export.** Never replace a placeholder with a real value and never "fix"
   a `REDACTED*` artifact. `live-cluster/` beats `gitops/` beats `charts/` beats `docs/`.
9. **One uniform configuration per component.** Site differences go in values, never in
   template forks or "remove this if" instructions.

---

## 3. Effort budget

| Resource | Limit |
|---|---|
| Subagents | At most 6 in total, at most 3 at once, each with a one-paragraph brief and a named output file. No subagent spawns subagents. If you are unsure a subagent's result is right, redo that part yourself; a result without `file:line` evidence does not count |
| Full reads | aigw-ui: `internal/render/`, `internal/syncer/`, `internal/kube/`, `internal/usage/`, `internal/overage/`, `internal/weights/`, `internal/store/capacity.go`, `internal/store/renderstate.go`, `cmd/server/main.go`, every `docs/*.md`. doomsday-stack: `CLAUDE.md`, `docs/ENTRY_ROUTE_MIGRATION.md`, `gitops/app-of-apps/README.md`, the glm53, qwen38 and judge charts (`values.yaml` and templates), `charts/llm-model/`, `charts/envoy-ai-gateway/values.yaml` and `templates/`, and in `live-cluster/`: `ns-envoy-ai-gateway-system/`, `ns-envoy-gateway-system/` and `ns-llm-glm53/{aigatewayroutes,httproutes,inferencepools,backends,backendtrafficpolicies,quotapolicies,llminferenceservices}*`. Everything else: grep and read only what a finding needs |
| Do not read | `research-pricing/`, `web/`, `release-notes/` except the README index, `gitops/platform-repo/`, PodMetrics, ReplicaSet, ControllerRevision, CSV and Lease dumps |
| Web | None. Upstream behaviour comes from sections 6 to 8 of this file, from the vendored charts in `charts/upstream-subcharts/` and from the CRD dumps in `live-cluster/cluster-scoped/crds/`. Do not state upstream behaviour from memory. What these sources do not cover is an open question |
| Time | At most one working day of agent time; the phases of section 9 carry time boxes |
| Output | About 12k words in total. Link to existing docs; do not restate them |

When you choose between reading one more file and thinking one step further about what
you already read, think.

### How to cite this file

Every research fact below has an id (`R12`) and a tag:

- `[FILE]`: you can check it yourself; the path is given. Check it, then cite the file.
- `[UPSTREAM]`: read in upstream source at the pinned version. You cannot check it.
  Cite it as "research pack R12". It counts as evidence.
- `[LAB]`: measured, on the lab pair unless the fact names another place. Cite it the
  same way. The lab has a small CPU model on one site, so a lab result proves that
  something works, not how fast.
- `[COMPUTED]`: worked out from an `[UPSTREAM]` formula, not measured.
- `[NOT TESTED]`: the source says it should work and nobody ran it. An ADR may list it
  as an option. A roadmap item built on it starts with the test.
- `[MEMORY]`: general knowledge, not checked against a source. Treat as an open
  question unless a file confirms it.
- `[OWNER]`: the owner said it, on the date given. It counts as evidence for what runs
  on the real platform. The charts and values in the export were brought in line on
  the same day; `live-cluster/` was not.

If a file in the repos contradicts this pack, the file wins. Say so in
`04-OPEN-QUESTIONS.md`. The ids are labels, not an order: R97 and later were added
after a review and sit in the area they belong to.

---

## 4. Ground truth, corrected

`AGENT.md` section 4 was the owner's understanding taken from the hub's docs. Several
points have changed since. Verify all of this in Phase 0.

### 4.1 Two states: the snapshot and what runs now

`live-cluster/` is a dump from 2026-10-12, taken before a migration. The three model
charts, the `envoy-ai` image tags and `docs/ENTRY_ROUTE_MIGRATION.md` describe what the
migration made: **every request takes the hub's entry route, and the charts put nothing
on the client listener**. The owner confirmed on 2026-10-13 that the real cluster has
finished it (`REAL_STATE` in section 0). Where this file says "the target", read "what
runs now".

So the current state in `00-CURRENT-STATE.md` is the migrated one: trace it from
`helm template` of the three model charts and the hub's render code. Use the snapshot
for what the migration did not touch (the pool, the scheduler config, the model server
arguments, the gateway's own objects), and trace a request through the snapshot's old
routes only where a finding needs the "before". Findings are about the current state.

Five settings on the real platform are newer than the snapshot (R124, R129 and R130 in
section 7). On GLM: the GPU memory share, the weight of the prefix scorer and a cap on
prefill per step. On the gateway: the log format and the quota timeout. The charts and
values in the export have them since 2026-10-13 and `live-cluster/` does not, so for
these five the charts win over the snapshot. For GLM's other arguments the snapshot
still wins, because `charts/glm53-bundled` is not the deployed branch. The model pods
run vLLM v0.29.0, not v0.30.0 (section 5).

### 4.2 What changed against AGENT.md section 4

| AGENT.md says | Now | Evidence |
|---|---|---|
| Anthropic requests go to a schema-Anthropic backend straight to the ranks and bypass the EPP | True in the snapshot only. In the target they enter the entry route, the gateway translates Anthropic to OpenAI, and they go through the peer listener, the pool and the EPP like any other request | `docs/ENTRY_ROUTE_MIGRATION.md`; chart invariants in `CLAUDE.md`; R60 |
| A site's own route is older and wins unless the fleet switch is on | In the target the model charts render only `<model>-peer` on the listener `peers`. There is no route of the site's own on the client listener | `helm template charts/qwen38-bundled`; `templates/peer.yaml` |
| Flow control is "the untested fix" for best-effort | It was tested on the lab with the EPP this platform runs. It exists in `charts/llm-model` and not in the three deployed model charts | R80 to R84 |
| No quota on a weighted route (agent-router#2833) | Fixed in the patched gateway images the target uses. Stock v1.2.0 still has it. The hub still leaves the weights out for a single site | R30, R31 |
| Health check of the entry route | Interval 3s and `panicThreshold: 1` since aigw-ui 0.12.3. With the old values a 15-minute soak lost 86 to 96% of requests | R90 to R93 |
| Quota is "called twice per request" | True, and in v1.2.0 the first call also charges 1 unit. Fixed upstream, in no release | R34 |

### 4.3 Still as AGENT.md describes it (verify, then link, do not restate)

- Cross-site path: per model the hub renders `fleet-<slug>`: a `Backend` with one
  endpoint per site, an `AIServiceBackend`, an `AIGatewayRoute` on the client listener,
  a `BackendTrafficPolicy` and an `EnvoyPatchPolicy`. `[FILE]` aigw-ui
  `internal/render/fleet.go`, `fleet_policy.go`.
- Site weights: declared `capacity-per-instance` times ready instances. `[FILE]`
  `internal/weights/`, `internal/kube/capacity.go`, `internal/store/capacity.go`.
- Site selection is the session hash only. `[FILE]` `fleet_policy.go`.
- Quota: one `QuotaPolicy` per model on the `AIServiceBackend`, buckets by
  `x-aigw-client-id`, counters in one Redis, fails open. `[FILE]` `internal/render/quota.go`.
- Best-effort: a second, more specific route `fleetbe-<slug>` for tenants past their
  budget, at most 200 of them. `[FILE]` `internal/render/fleet_besteffort.go`.

### 4.4 Control-plane facts already traced

Read in aigw-ui at commit `978d2be`. Line numbers in this file are from `2ff0b01`
(chart 0.12.3). If yours differ, grep the quoted name.

- The hub renders entry routes only when `FLEET_PEER_SNI` or `FLEET_DOMAIN` is set.
- `AUTO_SYNC` queues a sync after a change, waits about 1 second and syncs all
  clusters. Without it a sync is manual or by `SYNC_INTERVAL` (5m).
- A sync is a server-side apply with field manager `aigw-ui`, then a prune of objects
  with the label `app.kubernetes.io/managed-by=aigw-ui` that it did not render.
- `GET /api/v1/clusters/{id}/manifests` returns what a sync would write.
- Discovery takes model names from the gateway's `/v1/models` (it needs the cluster's
  key for that, or it falls back to routes), and backends from `AIGatewayRoute`s with an
  `Exact` match on `x-ai-eg-model`. It never deletes a model row, only endpoints.
- Cluster name is the zone name of the site. `fleet.go:36`.

---

## 5. Pinned versions

From the images in `live-cluster/` and the values in `gitops/app-of-apps/`.

| Component | Runs | Notes |
|---|---|---|
| Envoy Gateway | v1.9.2 | The vendored chart in the export is v1.9.1. The CRD dumps in `live-cluster/cluster-scoped/crds/` are the live ones and have the fields quoted below |
| Envoy proxy | distroless-v1.39.1 | |
| Envoy AI Gateway | Snapshot: v1.2.0-patched.1. Target: v1.2.0-patched.2 | Upstream moved to `theagentrouter/agent-router`. v1.2.0 (2026-10-07) is the newest release. See R30 |
| Rate limit service | `envoyproxy/ratelimit:0482748e` | |
| EPP | `llm-d-router-endpoint-picker:v0.10.0` | Repo `llm-d/llm-d-router`. Newest release is v0.11.0 (2026-09-27) |
| KServe | v0.21.0-rc1 | |
| vLLM | v0.29.0 in the model pods | `[OWNER]` 2026-10-13: the model pods run the LMCache 0.5.5 build of vLLM, which is 0.29; `docs/ARCHITECTURE.md:361` says the same. The `vllm-openai:v0.30.0` in the export is the node-prep image and the image of `charts/glm53-bundled`, which is not the deployed branch. The vLLM facts of this pack (R24, R62, R90, R125) were read at tag v0.29.0. The LMCache v0.5.5 Dockerfile takes the vLLM version as a build argument, so the exact build is whatever the image holds |
| LMCache | v0.5.5 | |
| aigw-ui | 0.12.3 (`2ff0b01`) | |

---

## 6. The thirteen areas: what is known, what is yours to decide

For each area decide: real problem, not a problem, or cannot tell. A finding without a
concrete consequence for a user is not a finding.

### Area 1. Site selection quality

**What the hub renders** `[FILE]` aigw-ui `internal/render/fleet_policy.go:25-40`,
`fleet.go:112-131`:

- R1. `loadBalancer.type: ConsistentHash`, `consistentHash.type: Headers` on the session
  headers. `zoneAware.weightedZones` only when the model has more than one site.
- R2. One `Backend` with one FQDN endpoint per site, `zone` = cluster name. Sites are
  sorted by name so that every gateway builds the same table.
- R3. Retry: `numRetries` = sites minus 1, on `connect-failure`, `reset` and status 503
  (also 429 on the best-effort route). An `EnvoyPatchPolicy` sets
  `host_selection_retry_max_attempts: 20` and the forwarded `Host`.

**What Envoy Gateway and Envoy do with it**:

- R4. `[UPSTREAM]` Envoy Gateway v1.9.2 turns `ConsistentHash` into the load balancing
  policy `envoy.load_balancing_policies.maglev` with `table_size`, and adds
  `locality_weighted_lb_config` when `weightedZones` is set
  (`internal/xds/translator/cluster.go:463-481`). It is always Maglev. There is no ring
  hash option. `[LAB]` The proxy's configuration showed exactly that: Maglev,
  `table_size` 65537, `locality_weighted_lb_config`.
- R5. `[FILE]` The only knobs of `consistentHash` are `type`, `headers`, `cookie`,
  `queryParams` and `tableSize` (default 65537, prime, at most 5000011). There is no
  bounded-load field. `live-cluster/cluster-scoped/crds/backendtrafficpolicies.yaml`.
- R6. `[UPSTREAM]` Envoy 1.39.1 gives each host the share
  `(host weight / sum in its zone) × (zone weight / sum of zone weights)` and builds the
  table from healthy hosts only, or from all hosts in panic mode
  (`thread_aware_lb_impl.cc:18-90`). With one endpoint per site, a site's share is its
  zone weight share.
- R7. `[UPSTREAM]` A request with no hash gets a random number each time
  (`thread_aware_lb_impl.cc:215`). So a client that sends no session header is dealt by
  weight on every request, and its conversation has no home site. `[LAB]` M2.
- R8. `[LAB]` Any weight change rebuilds the table, and the conversations that change
  site are the change in share and no more (M3). Weights 800/300 to 900/300 moved 2.0%
  of 3000 conversations, all from the small site to the big one. To 800/400: 6.7%, all
  the other way. To 801/300: 1 of 3000. Back to 800/300: every conversation was at its
  first site again. So a weight that flips between two values moves the same
  conversations back and forth each time.
- R9. `[FILE]` A retry after a 503 goes to another site for that one request
  (aigw-ui `fleet_policy.go:11-13`, `fleet.go:56-62`). The hash keeps no memory, so the
  next request of the conversation goes to its home site again.

**Bounded load (`hash_balance_factor`)**:

- R10. `[UPSTREAM]` Envoy 1.39.1 supports it with Maglev: when the factor is not 0 the
  Maglev balancer is wrapped in a bounded-load balancer (`maglev_lb.cc:98-103`). The
  field is `consistent_hashing_lb_config.hash_balance_factor` inside the Maglev policy
  config. The API refuses values under 100; 125 means "at most 125% of its fair share".
- R11. `[FILE]` Envoy Gateway v1.9.x has no API field for it (R5). The only way within
  constraint 1 is an `EnvoyPatchPolicy` on the generated cluster.
- R12. `[LAB]` The patch below was accepted (M5): the policy reported
  `Programmed=True`, the proxy rejected no update, the factor showed in the proxy's
  configuration, and the hub's own patch policy on the same Gateway stayed programmed.
  It was tested on a plain HTTPRoute, not on a hub entry route:

  ```yaml
  jsonPatches:
  - type: type.googleapis.com/envoy.config.cluster.v3.Cluster
    name: httproute/<gateway-ns>/fleet-<slug>/rule/0/backend/0
    operation:
      op: add
      path: /load_balancing_policy/policies/0/typed_extension_config/typed_config/consistent_hashing_lb_config
      value: {hash_balance_factor: 125}
  ```

  The cluster name ends in `/backend/0` only when `weightedZones` is set; without it the
  name is `httproute/<ns>/<route>/rule/0` (R30 explains why). A hub change has to render
  the right one of the two.
- R13. `[UPSTREAM]` The rule (`thread_aware_lb_impl.cc:265-380`):

  ```
  total_slots = floor(((active requests of the cluster + 1) × factor + 99) / 100)
  slots(site) = max(ceil(total_slots × share(site)), 1)
  a request goes to its home site while active(home) <= slots(home)
  otherwise to the first site, in an order fixed by the request's hash, that is within
  its slots; if none is, to the least overloaded one
  ```

- R14. Four consequences of R13 that decide whether this fits here:
  1. `[UPSTREAM]` The counts are the active requests **of one proxy process**. Two
     gateway replicas, or two entry sites, each see only their own traffic.
  2. `[UPSTREAM]` The bound is **relative**. It compares a site's part of the running
     requests with its weight share. It does not know that a site is idle or full.
  3. `[LAB]` At low concurrency the rounding matters. Shares 72.7% / 27.3%, factor
     125, eight conversations at once whose home is the small site and nothing else
     running: they landed `b b b a a b a a`, exactly as the formula gives. Half went to
     the big site although the small one ran three requests. With 20 other requests
     running on the big site, all eight stayed home. Of 60 at once whose home is the
     big site, 4 went to the small one.
  4. `[LAB]` The decision is **per request**. A conversation that overflows once is
     served cold at the other site, then returns home on its next request (all ids
     were home again after the load). For a 100k-token conversation that one request
     pays the full prompt again.
- R15. With no load the factor changes nothing: 0 of 3000 conversations moved when it
  was switched on (M5).

**Other upstream knobs in Envoy Gateway v1.9.x** `[FILE]` same CRD dump:

- R16. `slowStart` is refused with `ConsistentHash` (a validation rule), and so is
  `zoneAware.preferLocal`. Only `weightedZones` works with the hash.
- R17. `Backend.spec.fallback: true` plus `retry.numAttemptsPerPriority`: a fallback
  backend takes traffic only when the primary is unhealthy. This is priority failover.
- R18. `healthCheck.passive`: outlier detection (`consecutive5XxErrors`,
  `consecutiveGatewayErrors`, `baseEjectionTime`, `maxEjectionPercent` default 10).
- R19. `loadBalancer.endpointOverride`: a request header names the endpoint
  (`IP:port`); the configured balancer is the fallback.
- R20. `loadBalancer.type: BackendUtilization`: weights from load reports (ORCA) that
  the endpoints send. It is not a hash, so conversations are not pinned, and nothing in
  this stack is known to send such reports. `DynamicModule`: rejected by constraint 1.
- R21. `admissionControl`: the proxy refuses a rising share of requests when the recent
  success rate falls under a threshold.

**An upstream alternative to the hash, for the ADR's options**:

- R22. `[UPSTREAM]` The EPP version this platform runs (llm-d-router v0.10.0, and
  v0.11.0) contains a multi-cluster plugin family: an EPP whose endpoints are whole
  clusters. Plugin types: `multicluster-file-discovery` (peer clusters from a file, by
  gateway host), `multicluster-metrics-data-source` and `multicluster-metrics-extractor`
  (scrape each peer EPP's `llm_d_epp_average_queue_size` and
  `llm_d_epp_average_kv_cache_utilization` over HTTPS, with CA and client certificate
  options), `multicluster-session-affinity-filter`,
  `multicluster-approx-prefix-cache-producer` ("routes a repeated prefix back to its
  cluster"), `multicluster-prefix-cache-scorer`, `multicluster-queue-scorer`,
  `multicluster-kv-cache-utilization-scorer`.
  It would choose a site by prompt prefix and measured load, with no owner code.
- R23. `[NOT TESTED]` It has no documentation and no sample config in either release.
  Known blockers: a `QuotaPolicy` attaches only to an `AIServiceBackend`, and a route to
  a pool has none, so the quota at entry would be lost; and it is not known whether the
  gateway can open mTLS with a fixed server name to an endpoint that an EPP picked.
  Treat it as a later option and an open question, not as a design.

**Who sends the session header**:

- R97. `[LAB]` Measured on a workstation against a stand-in endpoint, Claude Code
  2.1.286: every model call carried `x-claude-code-session-id`. The main conversation
  and a subagent it started had the same value, so a subagent goes to its parent's
  site. A second run of the client had another value. The only request without the
  header was a connectivity check (`HEAD /api/hello`), which is not a model call. A
  header `x-claude-code-agent-id` was also seen in that run.
- R98. Not measured: the other clients, and the share of requests on the real platform
  that carry no session header. R89 gives that number from the access log with no code.
- R99. `[UPSTREAM]` How several hash headers combine. Envoy Gateway v1.9.2 writes one
  hash policy per header and marks none as terminal
  (`internal/xds/translator/route.go:747-765`). Envoy 1.39.1 combines the hash of every
  listed header that the request has (`source/common/http/hash_policy.cc`,
  `generateHash`). So a request with one of the headers hashes on that one.
- R100. `[NOT TESTED]` A fallback for header-less requests that follows from R99: add
  `x-aigw-client-id` to the hub's session headers, which are a setting
  (aigw-ui `internal/config/config.go:80`). A request without a session header would
  then hash on its key and stay at one site. A request with a session header would
  hash on both and still spread by conversation. The comment at `fleet_policy.go:29-31`
  ("would pin a customer to one site") holds only for the header-less requests. The
  price: on the day it is switched on every running conversation gets a new hash, and
  most are dealt again once.
- R101. A cookie hash is not a way out: it needs a client that stores a cookie from the
  gateway and sends it back. API clients do not, and Open WebUI calls the gateway from
  its server and already sends its own header.
- R102. `[LAB]` The default table size was enough for two sites: the split was within
  one point of the weights, and a weight change moved only the change in share (M1,
  M3). Nothing measured argues for a larger `tableSize`.

**Yours to decide**: the cost of hash-only under `TRAFFIC_SHAPE`; whether bounded load
helps or hurts 100k-token conversations given R14 (the author of this pack and its
reviewer both lean to no bounded load); what to do for header-less requests (R98, R100).

### Area 2. Capacity signal

- R24. `[UPSTREAM]` vLLM v0.29.0 metrics a hub could read: `vllm:num_requests_running`,
  `vllm:num_requests_waiting`, `vllm:num_requests_waiting_by_reason`,
  `vllm:kv_cache_usage_perc`, `vllm:num_preemptions`, `vllm:prefix_cache_queries`,
  `vllm:prefix_cache_hits`, `vllm:external_prefix_cache_queries`,
  `vllm:external_prefix_cache_hits`, `vllm:prompt_tokens_cached`,
  `vllm:request_queue_time_seconds`, `vllm:time_to_first_token_seconds`,
  `vllm:request_prefill_kv_computed_tokens`, `vllm:request_prefill_time_seconds`.
- R25. `[UPSTREAM]` EPP v0.10.0 serves `/metrics` on port 9090. Current names start with
  `llm_d_epp_`: `average_queue_size`, `average_running_requests`,
  `average_kv_cache_utilization`, `per_endpoint_queue_size`, `flow_control_queue_size`,
  `flow_control_pool_saturation`, `flow_control_requests_total`. The old prefixes
  `inference_pool_`, `inference_extension_` and `inference_objective_` are deprecated
  and still emitted.
- R26. Three ways to get a measured signal, all within constraint 1: the hub reads
  metrics and changes weights (hub code, control plane); bounded load in the proxy (R10,
  no code, relative, per proxy); the multi-cluster EPP (R22, not ready).
- R27. `[LAB]` A measured weight has a price that a declared one does not: every
  weight change moves conversations, by the change in share (R8). Hysteresis in the hub
  limits how often, not how many per change.

- R103. `[FILE]` The hub already moves weights in steps of one instance: up by at most
  one step per poll, down only after a second poll agrees, and a drain goes down one
  step per poll (aigw-ui `internal/weights/weights.go:18-32`). A reviewer's proposed
  design rule, which M3 supports: a weight never follows a live metric without steps
  and a minimum hold time.

**Yours to decide**: declared weight, declared weight plus bounded load, or measured
weight. Read the weight algorithm as coded first.

### Area 3. Quota path and the one Redis

- R30. `[UPSTREAM]` agent-router#2833 is the owner's own pull request, open on
  2026-10-13. Cause: with `weightedZones` Envoy Gateway builds one cluster per backend,
  named `httproute/<ns>/<route>/rule/<i>/backend/<j>`, and the gateway's quota code only
  knew the route-level name, so the route got no rate limit descriptors: nothing was
  counted and nobody was refused, silently. The patched images carry the fix.
- R31. The patched images, from the notes in the lab charts repo:

  | Patch | Upstream | Effect |
  |---|---|---|
  | 0001 | #2833, open | Quota works on a route with zone weights |
  | 0002 | #2837, open | Cached tokens are reported on Anthropic requests to an OpenAI backend. First version: cache writes are still charged as plain input |
  | 0003 | #2595, merged 2026-10-08, in no release | One scheduler filter per pool. Flow control needs it (R82) |
  | 0004 | not submitted as far as known | Thinking survives the Anthropic to OpenAI translation. In `patched.2` only |

  Controller and extproc must be the same build. Which tag a cluster runs:
  `gitops/app-of-apps/operators/envoy-ai/values.yaml` and the Deployment images in
  `live-cluster/`. **A site on stock v1.2.0 with a model on two or more sites enforces
  no quota on that model.**
- R32. `[FILE]` Quota settings of the gateway controller, vendored chart
  `charts/upstream-subcharts/ai-gateway-helm-v1.2.0/values.yaml:89-95`:
  `quotaRateLimitServiceAddr` (default `envoy-ai-gateway-ratelimit.envoy-gateway-system`,
  port 8081), `quotaRateLimitTimeout: 5` (seconds), `quotaRateLimitFailureModeDeny: false`.
  So the path fails open by default, and **a rate limit service that hangs can hold a
  request for up to 5 seconds before it is let through**. The timeout is the failure
  budget; it is a value, not code. The real platform sets 1 since 2026-10-13 (R130).
- R33. `[FILE]` Upstream does not deploy the rate limit service. The wrapper chart does:
  `charts/envoy-ai-gateway/values.yaml:321-364`. Its comments say every site and the hub
  must use the same Redis, and that while Redis is unreachable the rate limit pod is not
  ready and quotas are not enforced. `[LAB]` With the service down, requests were
  answered and not charged (`charts/llm-model/README.md:102-103`).
- R34. `[UPSTREAM]` Unreleased fixes on upstream main after v1.2.0, not in `patched.2`:
  - #2816 (2026-10-12): in v1.2.0 the check at request time has no cost set, and the
    rate limit service then counts 1. A request of 28 tokens is charged 29. `[LAB]`
    consistent with a counter of 399 after three answers of 131 tokens and three refused
    requests; not isolated as a test.
  - #2766 (2026-10-09): a changed `QuotaPolicy` did not reach the proxy until something
    else changed. Upstream now stamps `aigateway.envoyproxy.io/quota-policy-hash` on the
    generated HTTPRoute. This is the same trick as the hub's annotation
    `gateway.envoyproxy.io/aigw-ui-quota-revision` (aigw-ui `internal/render/quota.go:12-31`).
    Once a release has it, the hub's stamp on chart-owned routes can go.
  - #2695: weekly, monthly and yearly quota windows. v1.2.0 has `1s`, `1m`, `1h`, `1d` only.
- R35. `[FILE]` `QuotaPolicy` limits in the CRD (`live-cluster/cluster-scoped/crds/quotapolicies.yaml`):
  `perModelQuotas` at most 128, `targetRefs` at most 16, `clientSelectors` at most 8 per
  rule, `bucketRules` has no maximum, `mode` can only be `Shared`. The CRD text says of
  `serviceQuota` that "the descriptor set is not being set in the Envoy Configuration",
  so do not count on `serviceQuota` being enforced.
- R36. `[UPSTREAM]` Settings of the rate limit service at `0482748e`: `REDIS_TYPE`
  (default `SINGLE`), `REDIS_URL`, `REDIS_POOL_SIZE` 10, `REDIS_PIPELINE_WINDOW` and
  `REDIS_PIPELINE_LIMIT` (0, off), `LOCAL_CACHE_SIZE_IN_BYTES` (0, off; when on, a
  tenant that is already over its limit is refused from the pod's memory with no Redis
  call), `STOP_CACHE_KEY_INCREMENT_WHEN_OVERLIMIT`, `EXPIRATION_JITTER_MAX_SECONDS` 300,
  `BACKEND_TYPE` (`redis`). There is no setting that reconciles counters between two
  Redis instances. A Redis per site means a budget per entry site.
- R37. `[FILE]` Envoy Gateway has its own rate limit in `BackendTrafficPolicy.rateLimit`:
  `global` (at most 256 rules, needs a rate limit service and Redis too) and `local`
  (in the proxy, no Redis, at most 16 rules, with a cost that can come from the
  response). Sixteen rules cannot be one per tenant.
- R38. `[LAB]` On the entry path with `patched.2`: no key or a wrong key gets 401 in both
  protocols; a tenant with 300 tokens a minute was answered three times, then refused
  with 429 at the entry route in both protocols, and answered again in the next minute;
  a request that named another tenant in `x-aigw-client-id` was refused like the others.
  Cached prompt tokens were charged.

- R104. `[FILE]` What the extra unit of R34 is worth: the hub counts a priced model in
  credits, and one credit is a hundred-thousandth of a dollar
  (aigw-ui `internal/render/price.go:8-13`). So in dollar mode each request, answered
  or refused, adds $0.00001 to each bucket it is charged to. In token mode it adds one
  token. It matters for tests that expect an exact count, not for money.
- R105. `[FILE]` The fail-open is silent. The export has alert rules in
  `charts/generic-model`, `charts/qwen38-bundled` and `charts/llm-model`; none of them
  mentions the rate limit service or Redis. Whether the real cluster has such an alert
  elsewhere the owner does not know: check T3 in section 12.
- R106. `[NOT TESTED]` A reviewer suggested `LOCAL_CACHE_SIZE_IN_BYTES` (R36) so that
  tenants already over their limit stay refused during a Redis outage. Against it: the
  chart comment of R33 says the rate limit pod is not ready while Redis is unreachable,
  and a pod that is not ready receives no requests, so its local cache would not be
  asked. Test before building on it.

**Yours to decide**: central Redis with an explicit failure budget (R32), or a split,
given R36 and R37. State the RTT cost with `INTER_SITE_RTT`.

### Area 4. Scale of QuotaPolicy and SecurityPolicy

- R40. `[UPSTREAM]` Envoy Gateway v1.9.2 writes **every key into the configuration of
  every route** on the listener (`internal/xds/translator/api_key_auth.go:93-125`,
  `171-177`). Route configuration size grows with keys × routes, and one new or revoked
  key sends the whole route configuration to every proxy of every site.
- R41. `[FILE]` `apiKeyAuth.credentialRefs` is a list of Secrets, "the first one wins"
  for a duplicate client id. A Kubernetes Secret holds about 1 MiB `[MEMORY]`.
- R42. `[FILE]` The same CRD has JWT: `jwt.providers` (at most 16) with `localJWKS`
  (inline or from a ConfigMap, so it works disconnected), `claimToHeaders` (a claim
  becomes a request header, for example the tenant into `x-aigw-client-id`),
  `recomputeRoute`, and `authorization.rules` on JWT claims. Its configuration does not
  grow with tenants. Its price: a token is revoked by expiry, not by a list, and every
  client holds a token instead of a key.
- R43. `[FILE]` One quota rule per tenant per model, each a regular expression on the
  client id (aigw-ui `internal/render/auth.go:53-57`, `quota.go:84-104`). The best-effort
  route puts up to 200 tenants in one expression (`fleet_besteffort.go:25`).
- R44. Not known: the apply time and the proxy reload cost at `TENANT_SCALE`. Cheapest
  experiment: a Go test in `internal/render` that renders 400 tenants and reports object
  sizes; then one apply on a lab.

- R107. `[LAB]` Sizes measured by rendering with the hub's own code on a workstation
  (3 keys per tenant, 3 models, tenant names of 18 characters, the hub's real key
  length; JSON bytes):

  | Tenants | Keys | Secret `aigw-ui-api-keys` | One model's QuotaPolicy | Key data in ONE proxy route |
  |---|---|---|---|---|
  | 60 | 180 | 18 KB | 12 KB | 15 KB |
  | 400 | 1200 | 121 KB | 78 KB | 103 KB |
  | 2000 | 6000 | 606 KB | 389 KB | 516 KB |
  | 5000 | 15000 | 1.5 MB | 971 KB | 1.3 MB |

  About 100 bytes per key in the Secret, 195 bytes per tenant in a QuotaPolicy, 86 bytes
  per key in each route.
- R120. `[UPSTREAM]` The first hard limit is not an object, it is a message. Envoy
  Gateway sends its whole translation to the AI Gateway controller on every change
  (the live config has `includeAll: true` for routes, clusters, listeners and secrets:
  `live-cluster/ns-envoy-gateway-system/configmaps.yaml`). That message may be 4 MB:
  `extensionManager.maxMessageSize`, "Default: 4M" (Envoy Gateway v1.9.2,
  `api/v1alpha1/envoygateway_types.go:857-864`), and the controller's
  `maxRecvMsgSize`, default 4194304 (`ai-gateway-helm-v1.2.0/values.yaml:287-291`).
  `[FILE]` Neither is set in the export's values.
- R121. `[COMPUTED]` With R40 the key data alone is 86 bytes × keys × (routes on the
  client listener + 1). 400 tenants and 7 routes: about 0.8 MB, fine. 2000 tenants and
  7 routes: about 4.1 MB, over the limit. 400 tenants and 40 routes: the same. Past the
  limit the hook call fails; whether changes then stop reaching the proxies is
  `[NOT TESTED]`. Both limits are values, so they can be raised together, which moves
  the cliff and keeps the growth.
- R122. `[COMPUTED]` The next limits: the one Secret at about 1 MiB `[MEMORY]`, near
  10,000 keys; one QuotaPolicy at the API server's request size, several thousand
  tenants per model. The best-effort route stays small (4.5 KB at 200 tenants).
- R123. So for `TENANT_SCALE` of a few hundred tenants today's design holds, and what
  to watch is keys × routes against the 4 MB message. Nothing has been changed for
  scale: it is one Secret, one key policy, one quota rule per tenant per model.
- R108. Notes for a JWT option (R42). Signing a token is control-plane work, so the hub
  can be the issuer within constraint 1; the proxy checks the signature with its own
  filter. A client that fetches a fresh token before a session can live with a short
  expiry (`[MEMORY]` Claude Code can run a helper command that returns the key). A
  script with a fixed key cannot, so it needs a long-lived token, and revoking one then
  needs a deny rule per revoked token.

### Area 5. Hub unavailability

- R50. `[MEMORY]` An Envoy proxy keeps its last configuration when its control plane is
  away. Check the hub's `docs/operations.md` and `docs/security.md` for what they claim.
- R51. `[FILE]` Keys are a Secret on each cluster, so key checks need no hub. Quota
  needs the rate limit service and Redis: R32, R33.
- R52. The hub's sync is apply-then-prune by label (4.4). Decide what a hub that returns
  with an older Postgres does to live objects, from `internal/syncer/` and `HeldNames`
  (`fleet.go:180-194`).

- R109. `[FILE]` A reviewer proposed a guard: the hub refuses to apply or prune on a
  cluster whose stamped state is newer than its own database. Note for that ADR:
  `FleetRevision` is a hash of the fleet's content (`fleet.go:196-230`), so it can say
  "different" and not "newer". The guard needs a counter that only grows, kept in
  Postgres and stamped on the cluster.

### Area 6. GitOps and hub ownership

- R55. `[FILE]` What the hub assumes from charts is listed in `doomsday-stack/CLAUDE.md`
  ("Charts must provide what it assumes"). The hub has a self-test
  (`internal/selftest/`). The export has no `_validate.tpl`.
- R56. R34 (#2766) removes one shared object in time: the annotation on chart routes.

### Area 7. The Anthropic path

- R60. `[LAB]` With `patched.2`, a request to `/anthropic/v1/messages` went entry route,
  peer listener, scheduler, vLLM, and the answer contained thinking. Before the upgrade
  the same request returned none. Claude Code 2.1.286 ran a session with thinking
  against that gateway.
- R61. So in the target Claude Code gets the session hash, the quota (R38) and the EPP.
  The gap AGENT.md calls "the most important on the platform" is closed by the
  migration, which the real cluster has finished (4.1).
- R62. `[LAB]` `POST /anthropic/v1/messages/count_tokens` answers 422 on the entry path.
  Claude Code finished a session without it. `[UPSTREAM]` vLLM v0.29.0 serves
  `/v1/messages` and `/v1/messages/count_tokens` itself
  (`vllm/entrypoints/anthropic/api_router.py:51-101`). A gateway patch for it should
  report no usage, or a count is charged to the quota.
- R63. `[UPSTREAM]` Unreleased upstream: #2698 keeps Anthropic streaming overload errors
  in the stream.

- R110. **The gateway is a fork.** The target depends on four patches (R31): one is
  merged upstream and unreleased, two are open, and 0004, which the migration needs for
  thinking, is not submitted. Every upstream release is a re-port until they land. The
  roadmap carries this as an item of its own: per patch the upstream state, what breaks
  without it, and when it can be dropped. The owner has no plan yet: you write one,
  by the rules of T2 in section 12.
- R111. `[UPSTREAM]` A way to need fewer patches. The EPP v0.10.0 has an
  `anthropic-parser`, on by default next to the OpenAI one. It reads `/v1/messages` and
  `/v1/messages/count_tokens` and tracks usage, cached tokens included
  (`pkg/epp/framework/plugins/requesthandling/parsers/`). vLLM serves both paths itself
  (R62). So the scheduler and the model server can take an Anthropic request as it is.
- R112. `[NOT TESTED]` What is not known is the gateway: whether it can pass an
  Anthropic request untranslated through the entry route and the peer route to a pool,
  and still count its tokens for the quota. If it can, patches 0002 and 0004 are not
  needed and `count_tokens` works. Cheapest experiment: on a lab, an entry
  `AIServiceBackend` with the Anthropic schema, one request with thinking, one
  `count_tokens`, and a look at the quota counter.

### Area 8. Cost of the extra hop

- R65. `[LAB]` Owner's measurements, `charts/llm-model/README.md:111-120`: added per
  request 4.2 ms for one hop and 5.7 ms for two at a 2 KB prompt; 6.6 ms and 8.0 ms at
  100 KB; 5,316 and 4,355 requests a second at 32 connections. Not measured: 1 MB bodies
  at 48 concurrent, and the scheduler's own cost.
- R66. `[LAB]` Without a buffer limit the gateway refuses bodies above about 32 KB with
  413. `[FILE]` The export sets `bufferLimit: 50Mi` on both listeners
  (`charts/envoy-ai-gateway/values.yaml:205`, `templates/gateway.yaml:194`,
  `templates/peers.yaml:110`). A policy on one listener replaces the Gateway's, so each
  listener needs its own.
- R67. A benchmark on the real cluster reported a floor of about 200 ms through the
  chain. On the lab the whole chain took 29 ms at the median, so the hops alone do not
  explain it. It needs per-hop times from the real access log. The owner handed this
  to you: check T1 in section 12 says how to measure it and what each result means.

### Area 9. Best-effort

- R80. `[UPSTREAM]` EPP v0.10.0, `pkg/epp/flowcontrol/README.md`: flow control is off by
  default and is switched on with `featureGates: ["flowControl"]` in the
  `EndpointPickerConfig`. Off: requests over capacity go to each model server's own
  queue, and negative-priority requests are refused at once when the pool is saturated.
  On: requests wait **in the EPP** and are released by priority as capacity frees.
  Negative-priority requests wait under the same rules instead of being refused.
- R81. `[UPSTREAM]` Settings under `flowControl:` and their defaults: `defaultRequestTTL`
  60s (a request that cannot be dispatched in time is shed with a retryable error; keep
  it under the gateway's request timeout); per band `maxRequests` 5000 and `maxBytes` 1G;
  `defaultNegativePriorityBand` (a small `maxRequests` there makes best-effort refuse
  fast instead of queueing); `enableEviction` false (true cancels running
  negative-priority answers when higher ones wait); `saturationDetector`, default
  `utilization-detector`.
- R82. `[UPSTREAM]` The two detectors. `utilization-detector`: from model server metrics
  (queue depth and KV cache use), averaged over endpoints without weights; an endpoint
  with stale metrics counts as full, so **if the EPP cannot scrape the model servers,
  dispatch stops** and queued requests are shed at their TTL. `concurrency-detector`:
  counts requests in flight itself, `maxConcurrency` per endpoint (default 100), modes
  `requests`, `tokens`, `hybrid`; instant, but blind to the real GPU state; it sums over
  the pool, which favours the large endpoints.
- R83. `[LAB]` `charts/llm-model/README.md:105-109` and `values.yaml:38-60`: with KServe
  0.21's default scheduler config the class changed nothing, with up to 28 requests
  waiting. With `model.flowControl.enabled=true` and a gateway that has #2595 it worked,
  with `requestTTL: 60s`. On stock v1.2.0 every request timed out and got 429.
  `enableEviction` was not tested.
- R84. `[FILE]` The implementation exists in `charts/llm-model/templates/llminferenceservice.yaml:37-84`
  with the `concurrency-detector`. It is not in `glm53-bundled`, `qwen38-bundled` or
  `qwen36-judge`. The live scheduler config of those models is different (it uses
  `approx-prefix-cache-producer`, `inflight-load-producer`, `active-request-scorer`,
  `token-load-scorer`; see `live-cluster/ns-llm-glm53/llminferenceservices_serving_kserve_io.yaml`),
  so the flow control block has to be added to that config, not copied over it.
  `maxConcurrency` is per endpoint; check what one endpoint is for GLM (a rank port or
  a pod) before choosing a number.
- R85. `[FILE]` In a fleet, a 429 from a serving site is retried at the next site only
  on the best-effort route (`fleet.go:101-105`). A standard request that waits out its
  TTL gets 429 and the entry route does not retry it.

- R113. `[UPSTREAM]` The EPP reads one series per model server metric: of the series
  that match, the one with the newest timestamp, and the first one when none has a
  timestamp (`pkg/epp/framework/plugins/datalayer/extractor/metrics/spec.go`,
  `getLatestMetric`). A label selector can pick a series; nothing sums or averages
  several. This is the mechanism behind the owner's finding that the default scorers
  sampled one of eight engine labels.
- R114. It reaches flow control too. `utilization-detector`, the default once the gate
  is on (R81), uses the queue depth and KV cache use that this extractor produced.
  `concurrency-detector` counts requests in flight itself, through the
  `inflight-load-producer` that the live config already has, and is not affected. For
  GLM, set `concurrency-detector` explicitly and do not rely on the default.
- R115. `[FILE]` The GLM pool has 8 target ports and the service has 2 replicas, so 16
  endpoints (`live-cluster/ns-llm-glm53/inferencepools_inference_networking_k8s_io.yaml`
  and `llminferenceservices_serving_kserve_io.yaml`: `--data-parallel-size=8`,
  `--max-num-seqs=512`). `maxConcurrency` is per endpoint, so per rank port. Whether 512
  is per rank or per pod is yours to check before choosing the number.

**Yours to decide**: whether this is a uniform chart default (constraint 9), which
detector, and what the TTL is against the entry route's retry.

### Area 10. Model catalog skew

- R88. `[FILE]` The hub reads a revision and a capacity per instance from annotations on
  the `LLMInferenceService`; `charts/llm-model/values.yaml:68-76` says sites with
  different revisions of one model do not share traffic. Check how the hub enforces
  that in `internal/kube/capacity.go` and what the snapshot's services carry (glm53 and
  qwen38 in the snapshot have no annotation with `aigw` or `capacity` in its name).

### Area 11. Observability

- R89. `[FILE]` The gateway controller can turn request headers into labels on metrics,
  spans and access log lines: `requestHeaderAttributes`, `metricsRequestHeaderAttributes`,
  `logRequestHeaderAttributes` (`ai-gateway-helm-v1.2.0/values.yaml:97-119`). That gives
  a tenant and a session id per line with no code. Per site, the cache signal is
  `vllm:prefix_cache_hits / vllm:prefix_cache_queries` and `vllm:prompt_tokens_cached`
  (R24). Nothing in the stack joins sites into one view.

- R116. A reviewer's proposal for the missing cross-site view: each site's Prometheus
  federated to the hub cluster, with the tenant as a metric label and the session id in
  log lines only, because a label per session would multiply the number of series.
  Which product does the federation is an open choice.

### Area 12. Security seams

- R94. `[FILE]` The key policy sets `sanitize: true` and `forwardClientIDHeader`
  (aigw-ui `internal/render/auth.go:39-48`). The header strip list is in
  `charts/envoy-ai-gateway/templates/gateway.yaml:189-193`.
- R95. `[FILE]` The peer listener checks only `caCertificateRefs`
  (`charts/envoy-ai-gateway/templates/peers.yaml:98-99`; live policy `peers`). Any
  certificate signed by the fleet CA is accepted. The CRD also offers `subjectAltNames`
  (DNS names, URIs), `certificateHashes`, `spkiHashes` and `crl`.
- R96. `[LAB]` A narrow account for the hub's kubeconfig worked for registering a
  cluster, the first sync (8 objects applied, 6 removed) and discovery from routes:

  ```yaml
  # ClusterRole
  - apiGroups: [gateway.envoyproxy.io]
    resources: [envoypatchpolicies, backendtrafficpolicies, securitypolicies, backends]
    verbs: [get, list, create, patch, delete]
  - apiGroups: [aigateway.envoyproxy.io]
    resources: [quotapolicies, aigatewayroutes, aiservicebackends]
    verbs: [get, list, create, patch, delete]
  - apiGroups: [llm-d.ai]
    resources: [inferenceobjectives]
    verbs: [get, list, create, patch, delete]
  - apiGroups: [gateway.networking.k8s.io]
    resources: [gateways]
    verbs: [get, list]
  - apiGroups: [serving.kserve.io]
    resources: [llminferenceservices]
    verbs: [get, list]
  # Role in the gateway namespace
  - apiGroups: [""]
    resources: [secrets]
    verbs: [create]
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [aigw-ui-api-keys]
    verbs: [get, patch, delete]
  ```

  Plus a ServiceAccount, a token Secret and the two bindings. Not exercised with it: a
  best-effort model, and the hub's self-test. Compare with what `docs/security.md`
  proposes.

### Area 13. Cross-site cache and drain

- R117. `[LAB]` The hash keeps a conversation at one site (M1), and nothing in this
  stack shares a prefix cache between sites: vLLM's KV cache and LMCache belong to a
  site. A conversation that changes site starts cold there.
- R118. `[FILE]` What a drain is today: the operator marks a site drained, its weight
  goes down one step per poll to the lowest value, and after one more poll the site
  leaves the model's zones (aigw-ui `internal/store/capacity.go:41-42`, `109-111`,
  `132-135`; `internal/weights/weights.go:27-28`).
- R119. `[LAB]` What that does to conversations: each step moves the share that the step
  takes away (M3), and leaving the zones moves all that are left, as when a site goes
  away (M4). The hash has no memory, so it cannot tell a running conversation from a
  new one. "No new conversations here, let the running ones finish" cannot be said
  with weights.

**Yours to decide**: whether a cold move on drain is accepted for 100k-token
conversations, and what a drain should promise. If it should mean "finish what runs",
name the upstream piece that could do it, or write the feature request.

---

## 7. Already found and fixed: do not redo

**The 503 storm.** A soak lost 86 to 96% of requests to "no healthy upstream".

- R90. Cause, reproduced on the lab: vLLM closes an idle connection after 5 seconds
  (`[UPSTREAM]` `VLLM_HTTP_TIMEOUT_KEEP_ALIVE` default 5, `vllm/envs.py:109`); the entry
  route's health check ran every 5 seconds through the peer listener with no retry and
  met the closing connection; one failed check took the model's only endpoint out; with
  `panicThreshold: 0` every request was refused until the check passed twice.
- R91. `[FILE]` Why one failure was enough: "Without RetriableStatuses configured, any
  health check failure results in the host being immediately considered unhealthy"
  (CRD text of `healthCheck.active.unhealthyThreshold`). The hub sets
  `unhealthyThreshold: 3`, which therefore does not apply to a 503 answer.
- R92. `[LAB]` Fixes, each one alone gave 0 lost of about 530, against 93 of 533 before:
  aigw-ui 0.12.3 (interval 3s, `panicThreshold: 1`; `fleet_policy.go:58-82`); a retry on
  the chart's health route (`healthRetries: 2`); `llmisvc.keepAliveSeconds: 75`. All
  three model charts in the export have the last two. The GLM chart that is really
  deployed is the branch `bundled`, which is not in the export. The owner confirmed on
  2026-10-13 that this branch is migrated, and was not asked about these two values.
  If you can see the branch, check them; if not, ask. A soak with no 503 is the proof.
- R93. `[NOT TESTED]` A fourth option the CRD offers:
  `healthCheck.active.http.retriableStatuses: [503]` in the hub's policy. It would make
  the threshold of 3 real for a 503.

**Also done**: the entry-route migration and its test list
(`docs/ENTRY_ROUTE_MIGRATION.md`); the narrow account (R96); flow control in
`charts/llm-model` (R84).

**Benchmark findings nobody has acted on** (inputs for `01-GAPS.md`, not conclusions):
repeated prompts were slower than fresh ones on GLM. In the snapshot the GLM scheduler
weighs `prefix-cache-scorer` 3, the same as `active-request-scorer`; the chart in the
export has 1, and since 2026-10-13 so does the real platform (R124, R127).
`[UPSTREAM]` The `approx-prefix-cache-producer` guesses which endpoint
holds a prefix from what the EPP sent there (`autoTune` true, block size at least 64
tokens, `lruCapacityPerServer` 31250, matches at most 131072 tokens). A
`precise-prefix-cache-producer` that reads the model server's real cache events exists
in the same EPP version. `[NOT TESTED]`. A reviewer asks to rank this high: for long
conversations it may mean the cache path costs more than it saves. Two candidate
causes to separate: the approximate producer sends the next turn to another rank than
the one that holds the prefix, or fetching from LMCache is slower than computing again
at this chunk size. The test: one conversation at concurrency 1, with the prefix scorer
on and off, and with LMCache on and off.

**Settings changed on 2026-10-13, after the snapshot.**

- R124. `[OWNER]` 2026-10-13. Three values of the GLM deployment changed together:
  `--gpu-memory-utilization=0.92` (snapshot: 0.85), `prefix-cache-scorer` weight 1
  (snapshot: 3) and a new argument, `--long-prefill-token-threshold=8192`. The model
  runs with them, and a benchmark was running when this was written. `[FILE]`
  `charts/glm53-bundled/values.yaml` has the three values since that day (`:266`,
  `:284`, the weight at `:234`); `live-cluster/` does not, so do not quote it for them.
  In its other arguments that chart is still not the deployed branch. The owner named
  no other change, so those are the snapshot's (`--max-num-batched-tokens=32768`,
  `--max-num-seqs=512`, two pods of 8 ranks) until a file says otherwise.
- R125. `[UPSTREAM]` What the new argument does in vLLM v0.29.0: in one engine step a
  request gets at most that many prompt tokens
  (`vllm/v1/core/sched/scheduler.py:590-591`; the default 0 means no cap,
  `vllm/config/scheduler.py:70-72`). The total of a step stays
  `--max-num-batched-tokens`. `[COMPUTED]` With 32768 per step and a cap of 8192, up to
  four long prompts on one rank move forward together, where before the first one took
  the whole step. A long prompt that is alone on its rank gets 8192 per step, so a
  100,000-token prompt needs 13 steps instead of 4. `[FILE]` The owner measured the
  8192-per-step case on 2026-10-04, when 8192 was the total of a step: 100k-token
  prompts had a median time to first token of 22.8 s, and the total was raised for that
  reason (`charts/glm53-bundled/values.yaml:269-275`; the other arguments of that day
  are not the ones that run now). So expect that short prompts wait less behind long
  ones, and that a long prompt on a quiet rank starts later. `[NOT TESTED]` on the
  build that runs.
- R126. `[FILE]` The record on the GPU memory share. 0.93 crash-looped at engine start
  with CUDA out of memory on 2026-10-04, at a step total of 16384
  (`charts/glm53-bundled/values.yaml:257-265`). The rollout history of 2026-10-12 shows
  0.96 at 10:05 and 10:14, 0.95 at 10:26 and 10:31, 0.90 at 12:04, then 0.85 from 13:39
  on, together with `--max-num-seqs=512` and a step total of 32768
  (`live-cluster/ns-llm-glm53/replicasets_apps.yaml`; it does not say why a value was
  replaced). 0.92 starts (R124), so a failure at start is not the risk. Not known:
  whether it holds at peak, with full steps on long contexts. Running out of memory
  there stops a pod, which is 8 ranks and half of a site's GLM, and with `maxSurge: 0`
  nothing takes its place while it loads again. What 0.92 buys is more KV cache on the
  GPU. Whether that cache is what limits the platform is a question for
  `vllm:kv_cache_usage_perc` and `vllm:num_preemptions` (R24) under the benchmark.
- R127. `[UPSTREAM]` How the scheduler (v0.10.0) uses the weights. The total of an
  endpoint is the sum of weight times score, each score between 0 and 1, and the
  highest total is picked (`pkg/epp/scheduling/scheduler_profile.go:204-212`).
  `active-request-scorer`: an endpoint with no running request scores 1; a busy one
  scores `(max - count) / max`, where `max` is the count on the busiest endpoint, so
  the busiest always scores 0
  (`pkg/epp/framework/plugins/scheduling/scorer/activerequest/active_request.go:154-186`).
  `prefix-cache-scorer`: matched blocks divided by the blocks of the prompt
  (`.../scorer/prefix/plugin.go:157-166`). `token-load-scorer`: 1 minus the in-flight
  tokens divided by 4,194,304, so one 100k-token request moves it by 0.024
  (`.../scorer/tokenload/token_load.go:34,116-123`). The weights of these two load
  scorers are 3 and 1. `[COMPUTED]` A conversation stays on the rank that holds its
  prefix while 3 times the difference in the active score is less than the prefix
  weight times the match. With weight 3 it stayed in almost every case; it left when
  its rank was the busiest while another rank was idle. With weight 1 it leaves when
  another rank's active score is about a third higher. Two cases with the busiest rank
  at 4 requests: home at 3 and another at 2 is a difference of 0.25, and it stays under
  both weights; home at 4 and another at 2 is a difference of 0.5, and it stayed with
  weight 3 and leaves with weight 1.
- R128. What R124 means for the open finding above. The weight change tests one of its
  two candidate causes and makes the other worse. If repeated prompts were slow because
  they queued on the rank that held the prefix, weight 1 helps. If they were slow
  because a fetch from LMCache costs more than computing again, weight 1 sends more
  turns to a rank without the prefix, so more of them take that path, and R125 makes
  the prefill on such a rank slower when the rank is quiet. The three values went in
  together, so a benchmark after the change cannot say which one moved a number. To
  read one, compare before and after, per rank: `vllm:prefix_cache_hits /
  vllm:prefix_cache_queries` (the cache on the GPU), `vllm:external_prefix_cache_hits /
  vllm:external_prefix_cache_queries` (the cache behind the KV connector, here
  LMCache), `vllm:request_prefill_time_seconds`, and the time to first token of
  repeated against fresh prompts. A lower hit rate on the GPU with slower repeated
  prompts points at the weight. A slower single long prompt with the same hit rate
  points at R125. This is input for `01-GAPS.md` and for the tuning work; it is not a
  gateway finding.
- R129. `[OWNER]` 2026-10-13, `[FILE]`
  `charts/envoy-ai-gateway/templates/gateway.yaml:58-92` and
  `gateway.envoyProxy.accessLog.enabled: true` in that chart's `values.yaml:254-255`.
  The gateway writes its own JSON log format, not Envoy Gateway's default, and the
  format has two new fields: `request_tx_duration` and `response_duration`. The
  field names are not the default ones, which the lab had: the request id is
  `request_id` (default: `x-request-id`), and there is no `upstream_local_address`,
  `x-forwarded-for`, `downstream_remote_address` or
  `upstream_transport_failure_reason`. So a line no longer has the client's address
  or the reason a connection to a peer failed. T1 in section 12 and its script read
  both formats.
- R130. `[OWNER]` 2026-10-13, `[FILE]` the site values of `envoy-ai`
  (`gitops/app-of-apps/sites/site-a/prep/mces/cluster-mce-prep/cluster-llm-prep/envoy-ai/values.yaml`):
  `ai-gateway.controller.quotaRateLimitTimeout: 1`. `[UPSTREAM]` The flag is whole
  seconds, an int64 (`cmd/controller/main.go:280`), and becomes the timeout of the
  rate limit filter (`internal/extensionserver/quota_ratelimit.go:261`). So a rate
  limit service that hangs holds a request for 1 second, not 5 (R32), and then lets
  it through uncounted: during a slow period the fail-open of R105 comes sooner and
  for more requests, still with no alert (T3). The value is in the site layer, so
  another site keeps 5 unless its own values say otherwise. By constraint 9 its place
  is `gitops/app-of-apps/operators/envoy-ai/values.yaml`.

---

## 8. Lab measurements: two stand-in sites behind one route

Measured on 2026-10-13 on the lab's gateway (Envoy Gateway v1.9.2, Envoy 1.39.1, one
proxy pod). A plain HTTPRoute led to one `Backend` with two FQDN endpoints in the zones
`site-a` and `site-b`. Its `BackendTrafficPolicy` had the shape of R1: hash on the
session headers, `weightedZones`, an active health check every 3 seconds,
`panicThreshold: 1`, one retry. The two "sites" were small HTTP servers, not models. A
conversation is one value of `x-claude-code-session-id`; 3000 of them were used. All of
this is `[LAB]`.

| Id | Question | Result |
|---|---|---|
| M1 | Does a conversation always reach the same site, and is the split the weight share? | Yes. 3 passes over 3000 conversations: none was seen at two sites. Split 73.5% / 26.5% for weights 800/300 (the weight share is 72.7% / 27.3%) |
| M2 | What does a request without a session header get? | A site by weight, a new pick each time: 1455 and 545 of 2000 (72.8% / 27.2%) |
| M3 | How many of 3000 conversations move on a weight change? | 800/300 to 900/300: 59 (2.0%), all small to big. To 800/400: 202 (6.7%), all big to small. To 801/300: 1. Back to 800/300: 0 differ from the first run |
| M4 | A site goes away, then returns | Of its 796 conversations, 744 were answered by the other site and 52 still by its old server while that shut down. None of the other site's 2204 conversations moved. All 3000 requests sent in that time were answered. The share that the retry carried before the health check failed was not counted separately. After the site returned and passed its checks, all 3000 were at their first site again |
| M5 | Is the bounded-load patch of R12 accepted, and does overflow follow R13? | Accepted and visible in the proxy's configuration. No load: 0 of 3000 moved. Eight at once with home `site-b`, nothing else running: `b b b a a b a a`. The same eight while 20 ran on `site-a`: all stayed. Sixty at once with home `site-a`: 56 stayed, 4 went to `site-b`. Afterwards every id was home again |

What this does not show: two real clusters with a link between them; more than one proxy
pod or more than one entry site (R14.1); a hub entry route (the route was plain HTTP,
not an `AIGatewayRoute`); model servers with a real prefix cache, so the cost of a
moved conversation is not measured, only how many move.

---

## 9. Phases and time boxes

### Phase 0: orient (at most 1.5 h, at most 2 subagents)

1. Read yourself, fully: `doomsday-stack/CLAUDE.md`, `docs/ENTRY_ROUTE_MIGRATION.md`,
   and in aigw-ui `docs/architecture.md`, `how-it-works.md`, `platform-architecture.md`,
   `optimization.md`, `performance.md`, `security.md`.
2. Trace the data plane (yourself or a subagent, output
   `arch-review/evidence/data-plane-trace.md`): for each of the four request types the
   exact object chain as it runs now (4.1): names, namespaces, listener, which policy
   attaches where, which header is set or stripped where, where the body is buffered,
   where the quota is checked and charged. Take it from `helm template` of the three
   model charts plus the hub's render code, and from `live-cluster/` for what the
   migration did not touch.
3. Trace the control plane (output `arch-review/evidence/control-plane-trace.md`) from
   `aigw-ui/internal/` only: what is rendered from what state, apply and prune, the
   weight algorithm as coded, the best-effort loop, discovery, and every place the hub
   can fail and what the clusters do meanwhile. Start from 4.4 and correct it.
4. Write `00-CURRENT-STATE.md`. Mark every place where a doc and a file disagree, with
   the evidence.

### Phase 1: findings (at most 2 h, at most 2 subagents)

Go through the thirteen areas of section 6. For each: read the facts given, verify the
`[FILE]` ones, answer the "yours to decide" line. Subagents, if used, get disjoint
areas and write `arch-review/evidence/findings-<n>.md`. You write `01-GAPS.md`, ranked.
Also carry over the earlier review's open items if the files still show them: plain HTTP
on the client listener, idle timeouts, controllers that run as a single replica on the
L4 node, no NetworkPolicy, secrets left in completed Jobs.

Do the three checks of section 12 in this phase. T1 feeds Areas 3, 8 and 9, T2 feeds
Area 7, T3 feeds Area 3.

### Phase 2: target architecture and ADRs (at most 2.5 h, at most 1 subagent)

Write `02-TARGET-ARCHITECTURE.md`; the target must be reachable from today by the
roadmap. Write the ADRs. Mandatory topics, merged or split as the evidence suggests:
site selection; capacity signal (declared, measured, bounded load); quota topology;
tenant identity and key distribution at scale; the hub-unavailable contract; the
Anthropic client path (largely decided by the migration: record it and the remaining
gaps R62, R31); priority and best-effort; the GitOps and hub ownership contract.
Three more that a review of this file asked for: requests without a session header
(R98 to R100), the gateway fork (R110 to R112), and a hub that returns with older
state (R109). Area 13 needs a decision too; it may live in the site selection ADR.

Optional subagent `red-team`: give it only `02-TARGET-ARCHITECTURE.md` and the ADRs and
ask for the three strongest objections with evidence from the repos. Fold what
survives into the Consequences.

### Phase 3: roadmap and drafts (at most 2 h, at most 1 subagent for the check runs)

Write `03-ROADMAP.md` and the three drafts. What is known about the likely candidates;
decide from your evidence:

| Candidate | Repo and files | State |
|---|---|---|
| Narrow account for the hub, as a manifest | aigw-ui `deploy/`, `docs/security.md` | Written and lab-tested (R96). Small |
| Flow control as a uniform value in the three model charts | doomsday-stack `charts/{glm53-bundled,qwen38-bundled,qwen36-judge}` | Proven in `charts/llm-model` (R83, R84). Needs the patched gateway. Medium |
| Peer listener accepts named sites only | doomsday-stack `charts/envoy-ai-gateway/templates/peers.yaml`, a value | Field exists (R95). Small. Not tested |
| `retriableStatuses` on the entry route's health check | aigw-ui `internal/render/fleet_policy.go` | Not tested (R93). Small |
| Bounded load on the entry route | aigw-ui `internal/render/fleet_policy.go` | The patch works on a plain route (R12, M5), not tried on an entry route. R14 may speak against it for long conversations: decide in the ADR before drafting |
| A check that a rendered chart gives the hub what it assumes | aigw-ui `hack/`, or the charts | Nothing exists (R55). Medium |
| The key as a second hash input, for header-less requests | aigw-ui, a setting (`internal/config/config.go:80`), no code | Not tested (R100). Deals running conversations again once |
| An alert when the rate limit service is not ready | doomsday-stack `charts/envoy-ai-gateway`, a PrometheusRule | Nothing in the export (R105). Small |
| Timing fields in the gateway's access log, so every hop is split per request | doomsday-stack `charts/envoy-gateway`, a value (`EnvoyProxy` access log format) | Fields exist (T1). Small. Not tested |
| Shorter quota timeout as a value | doomsday-stack `charts/envoy-ai-gateway/values.yaml` | Field exists (R32). Small. Not tested |

Checks per repo. aigw-ui: `make test`, `gofmt`, `go vet`, `hack/check-duplication.sh`,
`hack/check-chart.sh`, `hack/check-release-note.sh` (chart `version` = `appVersion`, a
matching `docs/release-notes/v<version>.md` listed in its README; commit subjects are
plain outcome sentences). Charts: `helm lint` and `helm template` to stdout. Do not run
`helm dependency build` or `update`. Do not run `hack/deploy-hub.sh` or
`hack/seed-demo.py`. A draft may carry `-draft` in its note's title.

### Phase 4: stop (at most 30 min)

One `verifier` subagent reads only `01-GAPS.md`, the ADRs and `03-ROADMAP.md` and lists
every claim whose `file:line`, object name or research id does not exist. Fix those or
move them to open questions. Commit. Report.

---

## 10. Failure matrix (a table in `02-TARGET-ARCHITECTURE.md`)

Rows: hub pod down; Postgres down; hub Redis down; link between hub and a site down; one
site's gateway down; one site's model at 0 of N ready; one site's EPP down; a partition
where site A sees the hub and site B does not; a weight change of one instance; a key
revoked; a tenant's budget spent; a model removed from one site; a new site joins; a
site drained for maintenance.

Columns: what a client in flight sees; what a new request sees; what the quota does
(over, under, exact); what the session hash does to running conversations; time to
recover with no human; what the operator sees and where; today against the target.

Facts that fill cells: R6 and R8 (weights and the hash), M3 and M4 (what moves on a
weight change and when a site goes away), R9 (retry), R32 and R33 (Redis
and the rate limit service), R40 (a key change), R82 (the EPP loses its metrics), R90
to R92 (health check).

---

## 11. Style

- Evidence before opinion: `file:line` for code, `kind/name` in a namespace for live
  objects, `chart/path` for templates, `R<n>` for this pack. No citation means open
  question, not finding.
- The owner measured things. Build on the measurements in `performance.md`, the chart
  comments and this pack. Do not re-derive them.
- Prefer the upstream feature over the workaround, and give the version from this pack
  or the vendored chart, not from memory.
- Keep the owner's words: site, fleet, entry route, peer listener, tenant, class, pool,
  hub, sync, weight, drain.
- Short. A finding is a paragraph, an ADR fits on a screen, the roadmap is a table.

---

## 12. Three checks on the real platform

The owner answered four questions on 2026-10-13. The migration is finished (section 0).
The other three are yours: the first is for you to measure and to decide what follows
from it, and the owner does not know the answer to the other two. Each check says where
to look and what to do with each kind of result. Do them in Phase 1. Write what you ran
and what you saw in `arch-review/evidence/platform-checks.md`.

**Access.** These checks read from the real cluster. Constraint 7 stays in force for
everything else. Allowed here and nothing more: reading the logs of the gateway's proxy
pods; reading metrics (the proxy's `/stats`, the scheduler's and the model servers'
`/metrics`, or Prometheus); `get` on `PrometheusRule`, `ServiceMonitor` and
`PodMonitor`. No command that creates, changes, restarts or deletes anything. Before
the first command, check which cluster your session points at and write it in the
evidence file. If your session has no access, or you are not sure the access is
read-only, do not try: write the commands in `04-OPEN-QUESTIONS.md` for the owner to
run, and work from the output.

### T1. Where the 200 ms floor is (R67)

What the gateway's log can tell. `[LAB]`, on the same gateway versions:

- Every request writes two lines in the proxy's log: one for the entry route
  (`route_name` contains `fleet-<slug>`) and one for the peer route (`<model>-peer`).
  Both carry the same request id. That is the join key. Its field is `request_id` in
  the gateway chart's own format, which the real platform writes since 2026-10-13
  (R129), and `x-request-id` in Envoy Gateway's default format, which the lab had.
- Useful fields in both formats: `start_time`, `duration` (ms, the whole request, the
  stream included), `bytes_received` (the size of the request body), `response_code`,
  `response_flags`, `upstream_host`. Only the default format has
  `upstream_local_address`. Only the chart's format has `request_tx_duration` and
  `response_duration`.
- `x-envoy-upstream-service-time` is in the default format and is empty. So the
  default format does not split the peer hop from the model server. The chart's
  format does.
- On the lab, for a request with an 80-byte body, the peer line started 19 ms after the
  entry line, and the entry line's `duration` was 20 ms longer than the peer line's.

Compute per request, for answered requests (`response_code` 200):

```
A = peer.start_time - entry.start_time    time at the entry before the request reaches the
                                           peer listener: body upload, key check, body parse,
                                           quota check, connection to the peer
R = entry.duration - peer.duration - A     what the entry adds on the way back
P = peer.duration                          peer listener + scheduler + model server

and on each line of the chart's format (R129):
tx   = request_tx_duration                 from the start until the request is fully sent
                                           upstream: body upload, this proxy's own work,
                                           the connection
wait = response_duration - tx              what the upstream took to send its first byte
```

On the peer line, `tx` holds the second parse of the body and the scheduler's pick, and
`wait` is the model server's time to first byte. On the entry line, `tx` holds the key
check, the body parse and the first quota call, and `wait` is the whole peer hop. Both
are durations on one clock, so they also hold for a request that crossed sites.

Take the median and the 90th percentile of A and R in three groups of
`bytes_received`: under 10 KB, 10 KB to 300 KB, over 300 KB. The proxy may run as
several pods and a request's two lines can be in two of them, so read all pods
together. A cross-site request has its two lines in two clusters with two clocks: use
`duration`, `tx` and `wait` there, not A and R. This script does the join and reads both
formats. `[LAB]` It was run on the lab's lines, which are in the default format.
`[NOT TESTED]` Its part for the chart's format ran on made-up lines only:

```python
# usage: <the proxy pods' logs, all pods together> | python3 hops.py
import sys, json, datetime, collections
def ms(s): return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000
def num(r, k):
    try: return float(r.get(k))
    except (TypeError, ValueError): return None
pairs = collections.defaultdict(dict)
for line in sys.stdin:
    if not line.startswith("{"): continue
    try: r = json.loads(line)
    except ValueError: continue
    rid = r.get("request_id") or r.get("x-request-id")   # the chart's format, or the default
    if str(r.get("response_code")) != "200" or not rid: continue
    route = r.get("route_name") or ""
    side = "entry" if ("/fleet-" in route or "/fleetbe-" in route) else ("peer" if "-peer/" in route else None)
    if side: pairs[rid][side] = r
names = ["A", "R", "entry_tx", "entry_wait", "peer_tx", "peer_wait"]
groups = collections.defaultdict(lambda: {n: [] for n in names})
for p in pairs.values():
    if len(p) != 2: continue
    e, q = p["entry"], p["peer"]
    a = ms(q["start_time"]) - ms(e["start_time"])
    size = num(e, "bytes_received") or 0
    g = "under 10 KB" if size < 10_000 else ("10-300 KB" if size < 300_000 else "over 300 KB")
    v = groups[(e["route_name"].split("/")[2], g)]
    v["A"].append(a); v["R"].append(num(e, "duration") - num(q, "duration") - a)
    for side, r in (("entry", e), ("peer", q)):
        tx, rd = num(r, "request_tx_duration"), num(r, "response_duration")
        if tx is not None and rd is not None:
            v[side + "_tx"].append(tx); v[side + "_wait"].append(rd - tx)
pct = lambda x, f: sorted(x)[min(len(x) - 1, int(len(x) * f))]
for (route, g), v in sorted(groups.items()):
    print("%-28s %-12s n=%d" % (route, g, len(v["A"])))
    for n in names:
        if v[n]: print("    %-11s p50=%.0f p90=%.0f ms" % (n, pct(v[n], .5), pct(v[n], .9)))
```

Then four numbers that are not per request:

| Number | Where |
|---|---|
| Q: one quota call | `[LAB]` Proxy stat `cluster.ai_gateway_ratelimit_cluster.upstream_rq_time`. On the lab, with Redis in the same cluster: median 3 ms, 90th percentile 7 ms. There are two calls per request, and only the first is before the answer |
| S: the scheduler's time | `[UPSTREAM]` Scheduler metrics `llm_d_epp_scheduler_e2e_duration_seconds`, `llm_d_epp_request_processing_duration_seconds` and, per plugin, `llm_d_epp_plugin_duration_seconds` |
| V: the model server's own time to first token | `vllm:time_to_first_token_seconds`, with `vllm:request_queue_time_seconds` and `vllm:request_prefill_time_seconds` (R24) |
| C: time to first token as the client saw it | The benchmark report. Ask the owner for it if you do not have it |

`B = C - A - V` estimates the peer hop and the scheduler together. Compare it with S.
With the chart's format the split is in the log itself: `peer_tx` is the peer listener
and the scheduler, `peer_wait` is the model server, `entry_tx` is the entry before the
request leaves. Then B is a cross-check only, and where the table below says "B large"
read `peer_tx` for the scheduler rows and `peer_wait` for the model server row.

What to do with each result:

| Result | It means | Do |
|---|---|---|
| A is most of the floor, and about the same for small and large bodies | A fixed cost at the entry | Compare with Q. If Q is close to A, it is the quota call, which crosses to the hub's Redis: a finding in Area 3, ranked against `TARGETS`, and it decides the quota topology ADR. If Q is small, look at connection reuse to the peer: does the port in `upstream_local_address` of entry lines repeat across requests? All different means a new TLS connection per request; that is a finding in Area 8. The chart's format does not have this field (R129): then write the check as an open question with the one line the format needs |
| A grows with the body size | Upload and parsing of the body | Work out the ms per 100 KB. The lab measured about 2.4 ms more for 100 KB than for 2 KB on one hop (R65). Near that: not a finding. Far above: a finding in Area 8, and the open point of R65 (1 MB bodies) becomes the first experiment |
| A and R small, B large, S large | The scheduler | Read `plugin_duration_seconds` per plugin. The prefix producer hashes up to 131072 tokens of a prompt (section 7), so long prompts cost CPU there; check the scheduler's CPU limit. A finding in Area 9 or Area 1. The fix is values, not code |
| A and R small, B large, S small | The peer listener: the second parse of the body, or the connection to the model server | A finding in Area 8. It is the cost of the extra hop that R65 did not measure for large bodies |
| V alone is close to the floor, with queue time near 0 | Inside the model server before the first token: the chat template, tokenizing a long prompt, or the cache lookup | Not the gateway; write no gateway finding. Hand it to the tuning work together with "repeated prompts slower than fresh" (section 7) |
| A + R + B + V is far below C | Outside the platform: a client that opens a connection per request, DNS, the load balancer in front, or how the benchmark defines the first token (a thinking model's first content token comes after its thinking) | Not a platform finding. Write in `04-OPEN-QUESTIONS.md` how the benchmark should measure: reuse connections, run once from inside the cluster, state which event counts as the first token |
| The numbers cannot be had (no access, the log is too short, metrics are not scraped) | Unknown | An open question with the commands for the owner, and the roadmap candidate below |

What was a roadmap candidate here is done: since 2026-10-13 the gateway chart writes
both fields (R129). `[UPSTREAM]` In Envoy 1.39.1 `%REQUEST_TX_DURATION%` is the time
from the start until the request is fully sent upstream, and `%RESPONSE_DURATION%` the
time from the start until the first byte from upstream. What is left as a candidate
is three more fields in the same format. `%REQUEST_DURATION%` (from the start until
the request is fully received from the client) takes a slow upload out of `tx`.
`%UPSTREAM_LOCAL_ADDRESS%` brings back the connection check of the first row.
`%UPSTREAM_TRANSPORT_FAILURE_REASON%` says why a connection to a peer failed. Each is
one line in `charts/envoy-ai-gateway/templates/gateway.yaml`, the same for every site.
`[NOT TESTED]`.

### T2. A plan for the gateway patches (R110)

The owner has no plan yet. Write one, as part of the fork item in `03-ROADMAP.md`. For
each patch choose by these rules:

| The patch is | Recommend |
|---|---|
| Merged upstream, in no release (0003) | Nothing to send. Drop it at the first release that contains it. The standing roadmap item: on every upstream release, rebuild from the release plus the patches still needed, and retest with the hub's self-test |
| An open pull request (0001, 0002) | Keep it, and say what depends on it (R31): 0001 matters only for a model on two or more sites, 0002 only for the price of cached tokens on Anthropic requests. Do not propose leaving a patch out at some sites: constraint 9 wants one build everywhere |
| Not submitted (0004) | The highest risk, because the migration needs it and nobody upstream has seen it. Recommend one of two and rank them by effort: the owner submits it from the connected side, or the experiment of R112 shows it is not needed |

If the patch files are in a repo you have, read them, and for each patch with no pull
request write a draft description that the owner can submit: what breaks, the cause,
the change, how it was tested (R60). If they are not, list "the location of patch 0004"
as an input you need. On 2026-10-13 the lab charts repo held 0001 to 0003 under
`patches/agent-router-v1.2.0/`.

### T3. Is the silent fail-open watched (R105)

Look in this order:

1. Every repo you have, not only the two: search the alert rules for `ratelimit`,
   `redis` and `failure_mode`.
2. With the access above: `oc get prometheusrule -A -o yaml`, and search for the same
   words. Then check that the proxy's metrics are scraped at all: a `ServiceMonitor` or
   a `PodMonitor` that selects the proxy pods.

What counts as the signal. `[LAB]` The proxy keeps counters per entry route under
`cluster.<entry route cluster>.ratelimit.`; `ok` and `over_limit` were seen on the lab,
and `cluster.ai_gateway_ratelimit_cluster.upstream_rq_timeout` counts quota calls that
timed out. `[MEMORY]` Envoy also has `error` and `failure_mode_allowed` in the same
place; such counters appear only after the first failure, so their absence proves
nothing.

| Result | Do |
|---|---|
| A rule fires when the rate limit service has no ready pod, or when requests pass without a check | Cite it. No finding. Check that it also covers Redis being unreachable (R33: the pod is then not ready) |
| No such rule, and the proxy's metrics are scraped | A finding in Area 3: quotas can be off for hours and nobody is told. A small roadmap item: a rule in `charts/envoy-ai-gateway` on those counters, plus "the rate limit Deployment has no ready replica" |
| No such rule, and the proxy's metrics are not scraped | The same finding. The roadmap item starts with the scrape; until then the rule can use only the Deployment's ready replicas |
| You could not look | An open question with the one command for the owner |

---

Start with Phase 0. Do not ask what to do first. Ask only if a constraint of section 2
seems to conflict with `PAIN_TODAY`, and say which.
