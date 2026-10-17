{{/* Fullname: release-qualified prefix for all names. */}}
{{- define "qwen38.fullname" -}}
{{- if .Values.nameOverride -}}
{{- .Values.nameOverride -}}
{{- else -}}
{{- .Release.Name -}}
{{- end -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "qwen38.labels" -}}
app.kubernetes.io/name: {{ include "qwen38.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* model.uri pvc://<claim>/<subPath> derived from storage + model values. */}}
{{- define "qwen38.modelUri" -}}
pvc://{{ .Values.storage.models.pvcName }}/{{ .Values.model.subPath }}
{{- end -}}

{{/* nodeAffinity block for the static local PVs (shared by all). */}}
{{- define "qwen38.pvNodeAffinity" -}}
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
{{- define "qwen38.kvTransferConfig" -}}
{{- $e := .Values.lmcache -}}
{{- $extra := dict "lmcache.mp.host" (printf "tcp://%s.%s.svc.cluster.local" $e.name .Values.namespace) "lmcache.mp.port" ($e.server.port | toString) -}}
{{- if $e.isolatedIPC }}{{- $_ := set $extra "lmcache.mp.isolated_ipc" true }}{{- end }}
{{- dict "kv_connector" "LMCacheMPConnector" "kv_connector_module_path" "lmcache.integration.vllm.lmcache_mp_connector" "kv_role" "kv_both" "kv_connector_extra_config" $extra | toJson -}}
{{- end -}}

{{/* llmisvc.scheduler with flow control added (llmisvc.flowControl.enabled).
     The inline EndpointPickerConfig keeps its plugins and profile and gets
     the flowControl feature gate, the concurrency-detector, the fairness and
     ordering policies and a flowControl section. Same as in glm53-bundled. */}}
{{- define "qwen38.schedulerWithFlowControl" -}}
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
