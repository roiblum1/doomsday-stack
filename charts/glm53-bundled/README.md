# glm53-bundled

GLM-5.3 (FP8 MoE, 564G) on 2× B200 nodes as ONE KServe
`LLMInferenceService` (`serving.kserve.io/v1alpha2`, v0.21.0-rc1),
replicas 2 — one pod per node, DP8×EP8 intra-node over NVLink — behind
the llm-d router (EPP + InferencePool) and an Envoy AI Gateway
`AIGatewayRoute`.

## What the chart deploys (in this order conceptually)

1. **Namespace** + **ServiceAccount** (`s3sa`) + **SCC**
   (`glm53-model-serving`, cluster-scoped, requires cluster-admin).
2. **node-prep DaemonSet** — privileged `nsenter -t 1` loop that creates
   and keeps mounted manual LVM volumes (`llm-models` 1200G,
   `llm-cache` 300G) from the node VG at the same host path on every
   GPU node, labeled `container_file_t`. Idempotent; survives reboots
   (this cluster has no manageable MCO/MachineConfig).
3. **Static local PVs + pre-created PVCs** — one PV per volume whose
   `nodeAffinity` lists ALL target nodes at the same host path, so each
   pod mounts its own node's copy through ONE claim name
   (`pvc://<claim>/<subPath>` works with a single-Deployment CRD even at
   replicas > 1). `volumeName`-pinned → bound immediately, never pruned.
4. **Model pull Jobs** — one per node, s5cmd from S3 into that node's
   copy, idempotent via `.download-complete` marker (~3 min for 564G).
5. **One shared Gateway** (`envoy-ai-gateway`, VIP 192.0.2.7) for
   everything, with two listeners. Clients reach `http`, where only
   aigw-ui's entry routes live. This chart's routes and the KServe
   router HTTPRoute are on `peers` (mTLS). The former dedicated
   `glm53-kserve` Gateway + EnvoyProxy (VIP .146) was removed.
6. **LLMInferenceService** (`glm53-b200`) — the serving workload.
7. **AIGatewayRoute** (`glm53-peer`) on the peer listener: header
   `x-ai-eg-model: glm-5.3` → InferencePool, request timeout 3600s. And
   **HTTPRoute** (`glm53-peer-health`) for the entry route's health
   check, with a retry policy.
8. *(optional, `aiperf.enabled: true`)* **AIPerf benchmark Job**.

## Out-of-band prerequisites (NOT in this chart)

- **KServe v0.21.0-rc1** with the llm presets (`kserve-config-llm-template`
  base preset etc.) already installed in the `kserve` namespace.
- **Envoy AI Gateway** already installed: GatewayClass `envoy-ai-gateway`
  with the shared Gateway `envoy-ai-gateway` in
  `envoy-ai-gateway-system` (the AIGatewayRoute attaches to it).
- **EPP image patch**: the `kserve-config-llm-scheduler`
  `LLMInferenceServiceConfig` in the `kserve` namespace must point
  `spec.router.scheduler.template.containers[0].image` at the air-gapped
  mirror `registry-internal/kserve/llm-d/llm-d-router-endpoint-picker:v0.10.0`
  (default `ghcr.io` is unreachable). **Beware: this preset is
  Argo-managed and may be reverted** — re-patch if the EPP pods go into
  ImagePullBackOff.
- **S3 credentials secret** (`glm53-s3` with AWS_* keys) created
  out-of-band. Real credentials are never committed to this chart;
  `s3.create: true` exists only for test installs.

## Install

```bash
helm upgrade --install glm53 . -n llm-glm53 --create-namespace
# or with overrides:
helm upgrade --install glm53 . --set namespace=other-ns \
  --set-file ... etc.
```

The templates are self-ordering enough for `helm install` (namespace
object is applied first; the pull Jobs re-run idempotently). If
applying with plain manifests instead: `helm template glm53 . | oc apply -f -`.

Cold boot of the vLLM pods takes ~15–20 min per pod (safetensors load +
DeepGEMM JIT + torch.compile + MTP graph capture; startupProbe allows
30 min). Persistent JIT caches live on the cache PVC, so subsequent
boots are faster.

## Accessing the model

```bash
# Through the gateway (entry route -> peer listener -> EPP -> vLLM).
# Needs a tenant key from aigw-ui.
curl http://envoy-ai-gateway.envoy-gateway-system.svc/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'Authorization: Bearer <tenant key>' \
  -d '{"model":"glm-5.3","messages":[{"role":"user","content":"hi"}]}'
# Claude Code and other Anthropic clients: POST /anthropic/v1/messages
# with the same key and "model": "glm-5.3". Streaming is supported.
```

External clients use the shared gateway's LoadBalancer VIP. GLM-5.3
thinking mode consumes the output budget as reasoning tokens — pass
`chat_template_kwargs: {"reasoning_effort": "low"}` for content-bearing
responses.

## Known cosmetic issue

The isvc shows `InferencePoolReady=False` ("no Gateway controller has
accepted it"): nothing in the stack writes the InferencePool status
conditions (EG delegates pools to the AI-gateway extension manager).
The data plane is fully programmed and functional regardless.

## Uninstall

`helm uninstall` retains the PVs (reclaimPolicy `Retain`) and the data
on disk. To fully reclaim: delete the PVs, the host paths, and the
manual LVs (`lvremove`).
