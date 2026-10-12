# Security Sanitization — Methodology

This archive left a classified-adjacent, air-gapped environment. Every file in
`charts/`, `gitops/`, `live-cluster/` and `docs/` passed through the sanitization
pipeline described below; the raw pre-sanitization staging never left the source host.
**This document describes classes of data only — no real strings are reproduced.**

## What was sanitized (classes)

| Class | Treatment |
|---|---|
| Secret values (Secret `data`/`stringData`, API keys, S3 access/secret keys, TLS keys/certs, client CA bundles, mTLS keypairs, HMAC seeds, Redis passwords, session-encryption seeds) | **Values dropped; structure kept** (kind, keys, type, annotations, ownership). Any inline secrets found in pod specs (e.g. repair-job environment) were removed the same way |
| Internal registry hostnames + org path segments | Replaced with `registry-internal/` (optionally `/operators`, `/tools`) — image tags and `@sha256:` digests preserved after prefix strip |
| Domains (site, cluster apps domain, S3 endpoints, peer/fleet domain, LB hostname, git host) | Replaced with `example.internal`, `<s3-endpoint>`, `peers.llm.<site-domain>`, `<lb-hostname>`, `git.example.internal`-style placeholders; kube-internal `.svc.cluster.local` DNS kept |
| IP addresses (node host IPs, pod IPs, service ClusterIPs, gateway VIP, next-hops, pod CIDRs) | Dropped or replaced with RFC 5737 TEST-NET (`192.0.2.N`) / `<gateway-vip>` placeholders; MAC addresses zeroed |
| Cluster / site / MCE / node names | `cluster-llm-prep` (cluster), `site-a` (site), `gpu-node-1` / `gpu-node-2` (B200 nodes), `util-node-1` (L4 + utility node). Applies to node names embedded in job names, PV node affinity, providerIDs, tracking-ids |
| Usernames / personal / client identities (incl. the regexes in QuotaPolicy bucket selectors) | `user-1`…`user-N` (and `svc-*` for service identities) |
| Git URLs (internal chart repos, platform repos) | `https://git.example.internal/...` shape |
| Node identity fields (providerID, machineID, systemUUID, bootID, podCIDR, hostIP) and opaque blobs (standalone hex ≥40 chars, base64 ≥80 chars) | `REDACTED` / `REDACTED-HEX` / `REDACTED-B64` |
| `.git` directories, packaged `.tgz` (extracted instead), zip archives | Removed / extracted |

## What was preserved (by design)

- Image **tags and `@sha256:` digests** (registry prefix stripped) — needed for
  reproducibility and version pinning review.
- Chart names/versions, Argo CD app names, sync waves, sync options, `ignoreDifferences`.
- Ports, protocol choices, resource requests/limits, scheduling constraints
  (nodeSelectors, runtimeClassName, tolerations), all vLLM/gateway/operator **flag names
  and values**.
- Kubernetes-internal DNS (`.svc.cluster.local`) and object names (the stack's own
  names: `glm53`, `qwen38`, `judge`, `envoy-ai-gateway`, …).
- Bucket paths under `s3://llms/…` (path shape only; hostnames sanitized).
- Vendor/public references (github.com, kubernetes.io, envoyproxy.io, nvcr.io,
  `edge.urm.nvidia.com` as a vendor endpoint, quay.io) and hardware model context
  (e.g. "Dell PowerEdge XE9780, 8× B200").
- Versions: OCP 4.22, kernel, CUDA driver 580.126.20, chart/app versions.

## Verification — 3 passes

1. **Regex scan** (`verify1_regex.sh`): pattern sweep over the sanitized tree for every
   known-leaking shape — internal domains/TLDs, IPv4 (with carve-outs for RFC 5737 /
   documented keeps), MAC addresses, hostname patterns of the source cluster, registry
   prefixes, long hex/base64 blobs. Zero hits required.
2. **Independent token scanner** (`verify2_token.py`): a second implementation with a
   different matching strategy (tokenization + fuzzy/substring matching against an
   allowlist), catching constructs a regex misses (e.g. hostnames embedded in job names,
   split identifiers). Zero hits required.
3. **Adversarial agent audit**: a separate security-reviewer agent over the final tree
   instructed to "find ANY network-signed / org-identifying / secret data: hostnames,
   domains, IPs, usernames, unit numbers, keys, certs, git URLs — report file:line".
   Findings feed back into the sanitizer rules (or the offending doc) and the package is
   rebuilt; only a clean audit ships.

Pass logs ship as `docs/VERIFICATION.md`. The raw export also contained material the
automated classes intentionally drop — plaintext S3 credentials inside job pod specs,
full CA/certificate chains in ConfigMaps and Secrets, and the mTLS fleet keypairs — all
removed by the value-dropping rules above.

## Placeholder conventions (for the receiving agent)

| Placeholder | Meaning |
|---|---|
| `site-a` | the (single) site of this export |
| `cluster-llm-prep` | the OpenShift hosted cluster this export is taken from (siblings: `cluster-llm-prod`, `cluster-gpu-test`, `cluster-mce-prep`, `cluster-mce-prod`) |
| `gpu-node-1`, `gpu-node-2` | the two B200 serving nodes (Dell XE9780 class) |
| `util-node-1` | the L4 node (R760xa class) hosting the smaller models and control-plane pods |
| `registry-internal/` | the internal container registry (all image prefixes) |
| gateway VIP / `192.0.2.N` | the gateway LoadBalancer VIP / sanitized IPs (RFC 5737) |
| `peers.llm.example.internal` | the cross-site fleet peers SNI/domain |
| `<s3-endpoint>` / `s3://llms/…` | internal object storage; bucket-path shape kept |
| `user-1`…`user-N` | real client/user identities (QuotaPolicy buckets) |
| `git.example.internal` | internal git host |
| `cluster-*` | cluster name placeholders (MCE hubs and hosted OCP clusters) |

When cross-referencing `LIVE_STATE.md` against the live exports, expect these
placeholders everywhere a real identifier would appear; the mapping is deterministic per
file, so per-file consistency can be relied upon (the same node is always `gpu-node-1`).
