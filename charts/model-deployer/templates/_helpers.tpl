{{/* The name of every object: model.objectName, or the slug of model.name
     the way aigw-ui makes it (lowercase, anything but a-z 0-9 - becomes -). */}}
{{- define "md.name" -}}
{{- $n := .Values.model.objectName | default (regexReplaceAll "[^a-z0-9-]" (lower .Values.model.name) "-") -}}
{{- trimAll "-" $n -}}
{{- end -}}

{{- define "md.pool" -}}
{{- printf "%s-inference-pool" (include "md.name" .) -}}
{{- end -}}

{{- define "md.labels" -}}
app.kubernetes.io/name: {{ include "md.name" . }}
app.kubernetes.io/part-of: model-deployer
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* hf:// and s3:// models in cache mode are downloaded into a directory of
     the PVC named after the uri, so a new uri never mixes with old files
     and the Job (immutable) gets a new name. */}}
{{- define "md.cached" -}}
{{- if and (eq .Values.storage.mode "cache") (regexMatch "^(hf|s3)://" .Values.model.uri) -}}true{{- end -}}
{{- end -}}

{{- define "md.cacheDir" -}}
{{- sha256sum .Values.model.uri | trunc 10 -}}
{{- end -}}

{{- define "md.uri" -}}
{{- if include "md.cached" . -}}
{{- printf "pvc://%s-model/%s" (include "md.name" .) (include "md.cacheDir" .) -}}
{{- else -}}
{{- .Values.model.uri -}}
{{- end -}}
{{- end -}}

{{/* The vLLM arguments: the user's, then the ones this chart owns. */}}
{{- define "md.args" -}}
{{- $s := .Values.serving -}}
{{- $args := list -}}
{{- range $s.args }}{{ $args = append $args (toString .) }}{{ end -}}
{{- with .Values.model.maxModelLen }}{{ $args = append $args (printf "--max-model-len=%v" .) }}{{ end -}}
{{- $r := int $s.dataParallel.ranks -}}
{{- if gt $r 1 -}}
{{- $args = concat $args (list (printf "--data-parallel-size=%d" $r) (printf "--data-parallel-size-local=%d" $r) "--data-parallel-multi-port-external-lb" (printf "--data-parallel-supervisor-port=%d" (int $s.dataParallel.supervisorPort))) -}}
{{- end -}}
{{- toYaml $args -}}
{{- end -}}

{{- define "md.validate" -}}
{{- $v := .Values -}}
{{- if not $v.model.name }}{{ fail "model.name is required: what tenants send as \"model\"" }}{{ end -}}
{{- if not $v.model.uri }}{{ fail "model.uri is required: hf://, s3:// or pvc://" }}{{ end -}}
{{- if not (regexMatch "^(hf|s3|pvc|oci|gs|https?)://" $v.model.uri) }}{{ fail "model.uri must start with hf://, s3://, pvc://, oci://, gs:// or http(s)://" }}{{ end -}}
{{- if not (regexMatch "^[a-z]([a-z0-9-]{0,40}[a-z0-9])?$" (include "md.name" .)) }}{{ fail (printf "the object name %q must be a DNS label of at most 42 characters that starts with a letter: set model.objectName" (include "md.name" .)) }}{{ end -}}
{{- if not (has $v.storage.mode (list "download" "cache")) }}{{ fail "storage.mode must be download or cache" }}{{ end -}}
{{- range $v.serving.args -}}
{{- if not (regexMatch "^[^\\s'\"$`\\\\;&|<>(){}*?\\[\\]!#~]+$" (toString .)) }}{{ fail (printf "serving.args: %q is not one plain token (KServe runs the arguments through bash eval)" (toString .)) }}{{ end -}}
{{- if regexMatch "^--(max-model-len|max_model_len|tensor-parallel-size|tensor_parallel_size|data-parallel-size|data_parallel_size|data-parallel-multi-port|data-parallel-supervisor-port|kv-transfer-config|kv_transfer_config)" (toString .) }}{{ fail (printf "serving.args: %q is set by the chart (model.maxModelLen, serving.tensorParallel, serving.dataParallel)" (toString .)) }}{{ end -}}
{{- end -}}
{{- if hasKey $v.serving.env "VLLM_ADDITIONAL_ARGS" }}{{ fail "serving.env: VLLM_ADDITIONAL_ARGS goes through bash eval; use serving.args" }}{{ end -}}
{{- if and (gt (int $v.serving.tensorParallel) 1) (gt (int $v.serving.dataParallel.ranks) 1) }}{{ fail "serving.tensorParallel and serving.dataParallel.ranks: choose one (put other shapes in serving.args)" }}{{ end -}}
{{- if and $v.scheduler.flowControl.enabled (not $v.scheduler.config) (not $v.scheduler.flowControl.maxConcurrency) }}{{ fail "scheduler.flowControl.maxConcurrency is required with flowControl.enabled: requests in flight per endpoint (InferencePool port / data-parallel rank), not per pod" }}{{ end -}}
{{- if not (has ($v.scheduler.flowControl.fairnessPolicy | default "") (list "" "round-robin-fairness-policy")) }}{{ fail "scheduler.flowControl.fairnessPolicy must be empty or round-robin-fairness-policy" }}{{ end -}}
{{- end -}}
