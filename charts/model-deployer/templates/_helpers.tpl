{{/* The LLMInferenceService's name: llmisvc.name, or the slug of model.name
     (lowercase, anything but a-z 0-9 - becomes -), as aigw-ui makes it. */}}
{{- define "md.llmisvcName" -}}
{{- .Values.llmisvc.name | default (regexReplaceAll "[^a-z0-9-]" (lower .Values.model.name) "-" | trimAll "-") -}}
{{- end -}}

{{/* Fullname: the prefix of the chart's own object names (node prep, PVs,
     pull jobs, StorageClass). nameOverride, else the LLMInferenceService's
     name. */}}
{{- define "md.fullname" -}}
{{- .Values.nameOverride | default (include "md.llmisvcName" .) -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "md.labels" -}}
app.kubernetes.io/name: {{ include "md.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* The pool KServe makes for the LLMInferenceService. */}}
{{- define "md.pool" -}}
{{- printf "%s-inference-pool" (include "md.llmisvcName" .) -}}
{{- end -}}

{{/* Required-field guards: fail the render early instead of emitting
     objects with empty names. Called from serviceaccount.yaml (always
     rendered). */}}
{{- define "md.requiredChecks" -}}
{{- $v := .Values -}}
{{- if not $v.namespace }}{{ fail "values: namespace is required (the Argo CD app's projectNamespace)" }}{{ end -}}
{{- if not $v.model.name }}{{ fail "values: model.name is required: what tenants send as \"model\"" }}{{ end -}}
{{- if not (regexMatch "^[a-z]([a-z0-9-]{0,40}[a-z0-9])?$" (include "md.llmisvcName" .)) }}{{ fail (printf "values: the LLMInferenceService name %q must be a DNS label of at most 42 characters that starts with a letter (set llmisvc.name)" (include "md.llmisvcName" .)) }}{{ end -}}
{{- if and $v.scc.create (not $v.scc.name) }}{{ fail "values: scc.name is required when scc.create" }}{{ end -}}
{{- if and $v.lmcache.enabled (not $v.lmcache.name) }}{{ fail "values: lmcache.name is required when lmcache.enabled" }}{{ end -}}
{{- if and $v.lmcache.enabled $v.llmisvc.kvCacheOffloading }}{{ fail "values: lmcache.enabled and llmisvc.kvCacheOffloading exclude each other (one connector owns the KV cache)" }}{{ end -}}
{{- if and $v.modelCache.enabled $v.model.subPath }}{{ fail "values: modelCache and model.subPath exclude each other (cache downloads model.uri; subPath reads the node-prep PVC)" }}{{ end -}}
{{- if and $v.modelCache.enabled (not (regexMatch "^(hf|s3)://" $v.model.uri)) }}{{ fail "values: modelCache needs model.uri hf://... or s3://..." }}{{ end -}}
{{- if and (not $v.model.subPath) (not $v.model.uri) }}{{ fail "values: set model.subPath (the node-prep PVC) or model.uri (hf://, s3://, pvc://)" }}{{ end -}}
{{- range (concat ($v.llmisvc.args | default list) ($v.llmisvc.extraArgs | default list)) -}}
{{- if not (or (regexMatch "^[^\\s'\"$`\\\\;&|<>(){}*?\\[\\]!#~]+$" (toString .)) (regexMatch "^--[A-Za-z0-9._-]+='[^']*'$" (toString .))) }}{{ fail (printf "llmisvc.args: %q is not one plain token or --option='value' (KServe runs the arguments through bash eval)" (toString .)) }}{{ end -}}
{{- if regexMatch "^--kv[-_]transfer[-_]config" (toString .) }}{{ fail "llmisvc.args: --kv-transfer-config is appended by the chart when lmcache.enabled" }}{{ end -}}
{{- if and $v.model.maxModelLen (regexMatch "^--max[-_]model[-_]len" (toString .)) }}{{ fail "llmisvc.args: --max-model-len is set from model.maxModelLen; set it in one place" }}{{ end -}}
{{- end -}}
{{- if hasKey ($v.llmisvc.env | default dict) "VLLM_ADDITIONAL_ARGS" }}{{ fail "llmisvc.env: VLLM_ADDITIONAL_ARGS goes through bash eval; use llmisvc.args" }}{{ end -}}
{{- end -}}

{{/* Weights downloaded once into a PVC (modelCache): a directory named after
     the uri, so a new uri never mixes with old files and the Job (whose
     spec cannot change) gets a new name. */}}
{{- define "md.cacheDir" -}}
{{- sha256sum .Values.model.uri | trunc 10 -}}
{{- end -}}

{{/* model.uri as KServe gets it:
     - model.subPath: pvc://<storage.models.pvcName>/<subPath>, the node-prep
       PVC the pull jobs filled (the controller mounts it read-only at
       /mnt/models and strips the storage-initializer);
     - modelCache.enabled: pvc://<name>-model/<dir>, filled by the chart's Job;
     - otherwise model.uri verbatim (an s3:// or hf:// uri the
       storage-initializer downloads into the pod at every start). */}}
{{- define "md.modelUri" -}}
{{- if .Values.model.subPath -}}
pvc://{{ .Values.storage.models.pvcName }}/{{ .Values.model.subPath }}
{{- else if .Values.modelCache.enabled -}}
pvc://{{ include "md.llmisvcName" . }}-model/{{ include "md.cacheDir" . }}
{{- else -}}
{{ .Values.model.uri }}
{{- end -}}
{{- end -}}

{{/* StorageClass name: explicit value or <fullname>-local-static. */}}
{{- define "md.storageClassName" -}}
{{- if .Values.storage.className -}}
{{ .Values.storage.className }}
{{- else -}}
{{ include "md.fullname" . }}-local-static
{{- end -}}
{{- end -}}

{{/* nodeAffinity block for the static local PVs (shared by all). */}}
{{- define "md.pvNodeAffinity" -}}
nodeAffinity:
  required:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
{{ toYaml .Values.nodes.hostnames | indent 14 }}
{{- end -}}

{{/* The JSON the vLLM pods need in --kv-transfer-config, mirroring what the
     LMCache operator writes into the <engine>-connection ConfigMap.
     Compact (no spaces); the caller wraps it in single quotes because the
     kserve preset launcher evals `vllm serve ... $@` and a bare JSON blob
     would hit bash brace expansion there. */}}
{{- define "md.kvTransferConfig" -}}
{{- $e := .Values.lmcache -}}
{{- $extra := dict "lmcache.mp.host" (printf "tcp://%s.%s.svc.cluster.local" $e.name .Values.namespace) "lmcache.mp.port" ($e.server.port | toString) -}}
{{- if $e.isolatedIPC }}{{- $_ := set $extra "lmcache.mp.isolated_ipc" true }}{{- end }}
{{- dict "kv_connector" "LMCacheMPConnector" "kv_connector_module_path" "lmcache.integration.vllm.lmcache_mp_connector" "kv_role" "kv_both" "kv_connector_extra_config" $extra | toJson -}}
{{- end -}}

{{/* llmisvc.scheduler with flow control added to its own scheduler config
     (as glm53-bundled does): the featureGate, a concurrency-detector with
     maxConcurrency per endpoint, the fairness and ordering policies, and
     the flowControl block. The config's own plugins and profiles stay. */}}
{{- define "md.schedulerWithFlowControl" -}}
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
       v0.11.0's config loader resolves it. */ -}}
{{- $_ := set $flow "defaultNegativePriorityBand" (merge (dict "maxRequests" (toString .)) $band) -}}
{{- end -}}
{{- $_ := set $inline "featureGates" $gates -}}
{{- $_ := set $inline "plugins" $plugins -}}
{{- $_ := set $inline "flowControl" $flow -}}
{{- toYaml $sched -}}
{{- end -}}
