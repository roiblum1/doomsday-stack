{{/* Fullname: release-qualified prefix for all names. */}}
{{- define "genericmodel.fullname" -}}
{{- if .Values.nameOverride -}}
{{- .Values.nameOverride -}}
{{- else -}}
{{- .Release.Name -}}
{{- end -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "genericmodel.labels" -}}
app.kubernetes.io/name: {{ include "genericmodel.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Required-field guards: fail the render early instead of emitting
     objects with empty names. Called from namespace.yaml (always
     rendered). */}}
{{- define "genericmodel.requiredChecks" -}}
{{- if not .Values.namespace -}}
{{- fail "values: namespace is required" -}}
{{- end -}}
{{- if not .Values.model.name -}}
{{- fail "values: model.name is required" -}}
{{- end -}}
{{- if not .Values.scc.name -}}
{{- fail "values: scc.name is required" -}}
{{- end -}}
{{- if not .Values.llmisvc.name -}}
{{- fail "values: llmisvc.name is required" -}}
{{- end -}}
{{- if and .Values.aigatewayRoute.enabled (not .Values.aigatewayRoute.name) -}}
{{- fail "values: aigatewayRoute.name is required when aigatewayRoute.enabled" -}}
{{- end -}}
{{- if not .Values.serviceAccount.name -}}
{{- fail "values: serviceAccount.name is required" -}}
{{- end -}}
{{- if not .Values.images.vllm -}}
{{- fail "values: images.vllm is required" -}}
{{- end -}}
{{- if .Values.directBackend.enabled -}}
{{- if not .Values.directBackend.name -}}
{{- fail "values: directBackend.name is required when directBackend.enabled" -}}
{{- end -}}
{{- if not .Values.directBackend.backendName -}}
{{- fail "values: directBackend.backendName is required when directBackend.enabled" -}}
{{- end -}}
{{- if eq .Values.directBackend.style "ranks" -}}
{{- if not .Values.directBackend.ranksService.name -}}
{{- fail "values: directBackend.ranksService.name is required when directBackend.style is ranks" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.aigatewayRoute.claudeAlias.enabled (ne .Values.directBackend.schema "Anthropic") -}}
{{- fail "values: aigatewayRoute.claudeAlias is only valid with directBackend.schema: Anthropic (claude-* ids are an Anthropic-protocol client artifact)" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.lmcache.enabled (not .Values.lmcache.name) -}}
{{- fail "values: lmcache.name is required when lmcache.enabled" -}}
{{- end -}}
{{- end -}}

{{/* model.uri: pvc://<claim>/<subPath> when model.subPath is set (the
     controller mounts the pre-created PVC read-only at /mnt/models and
     strips the storage-initializer); otherwise model.uri verbatim (e.g.
     s3:// -- the kserve storage-initializer downloads into the pod). */}}
{{- define "genericmodel.modelUri" -}}
{{- if .Values.model.subPath -}}
pvc://{{ .Values.storage.models.pvcName }}/{{ .Values.model.subPath }}
{{- else -}}
{{ .Values.model.uri }}
{{- end -}}
{{- end -}}

{{/* OpenAI-protocol model id that keeps the EPP/InferencePool path:
     aigatewayRoute.openaiModel when set, else the derived publishers id
     (the kserve base preset also serves it as a second
     --served-model-name). */}}
{{- define "genericmodel.openaiModel" -}}
{{- if .Values.aigatewayRoute.openaiModel -}}
{{ .Values.aigatewayRoute.openaiModel }}
{{- else -}}
publishers/{{ .Values.namespace }}/models/{{ .Values.model.name }}
{{- end -}}
{{- end -}}

{{/* StorageClass name: explicit value or <fullname>-local-static. */}}
{{- define "genericmodel.storageClassName" -}}
{{- if .Values.storage.className -}}
{{ .Values.storage.className }}
{{- else -}}
{{ include "genericmodel.fullname" . }}-local-static
{{- end -}}
{{- end -}}

{{/* Workload service name the direct backend's workload-svc style points
     at: explicit value or kserve's convention <llmisvc.name>-kserve-workload-svc. */}}
{{- define "genericmodel.workloadServiceName" -}}
{{- if .Values.directBackend.workloadService.name -}}
{{ .Values.directBackend.workloadService.name }}
{{- else -}}
{{ .Values.llmisvc.name }}-kserve-workload-svc
{{- end -}}
{{- end -}}

{{/* Rule name for the direct backend's AIGatewayRoute rule: explicit
     value (parity with a migrated per-model chart) or direct-native. */}}
{{- define "genericmodel.directRuleName" -}}
{{- if .Values.directBackend.ruleName -}}
{{ .Values.directBackend.ruleName }}
{{- else -}}
direct-native
{{- end -}}
{{- end -}}

{{/* nodeAffinity block for the static local PVs (shared by all). */}}
{{- define "genericmodel.pvNodeAffinity" -}}
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
{{- define "genericmodel.kvTransferConfig" -}}
{{- $e := .Values.lmcache -}}
{{- $extra := dict "lmcache.mp.host" (printf "tcp://%s.%s.svc.cluster.local" $e.name .Values.namespace) "lmcache.mp.port" ($e.server.port | toString) -}}
{{- if $e.isolatedIPC }}{{- $_ := set $extra "lmcache.mp.isolated_ipc" true }}{{- end }}
{{- dict "kv_connector" "LMCacheMPConnector" "kv_connector_module_path" "lmcache.integration.vllm.lmcache_mp_connector" "kv_role" "kv_both" "kv_connector_extra_config" $extra | toJson -}}
{{- end -}}
