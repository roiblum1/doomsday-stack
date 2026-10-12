{{- define "gpu.labels" -}}
app.kubernetes.io/name: gpu
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "gpu.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}

{{/* clock-lock helpers */}}
{{- define "clock-lock.name" -}}
{{- default "clock-lock" .Values.clockLock.nameOverride -}}
{{- end -}}
{{- define "clock-lock.chart" -}}
{{- printf "%s-%s" "clock-lock" .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "clock-lock.labels" -}}
app.kubernetes.io/name: clock-lock
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ include "clock-lock.chart" . }}
{{- end -}}
{{- define "clock-lock.selectorLabels" -}}
app.kubernetes.io/name: clock-lock
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
