{{/*
Expand the name of the chart.
*/}}
{{- define "rdma-exporter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rdma-exporter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels matching the currently deployed working cluster.
The instance label is hard-coded to the subchart name so that
Service/ServiceMonitor selectors continue to match when this chart
is consumed as a subchart of an umbrella release.
*/}}
{{- define "rdma-exporter.labels" -}}
app.kubernetes.io/name: {{ include "rdma-exporter.name" . }}
app.kubernetes.io/instance: {{ include "rdma-exporter.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rdma-monitoring
helm.sh/chart: {{ include "rdma-exporter.chart" . }}
{{- end }}

{{/*
Selector labels used by DaemonSet and Service resources.
*/}}
{{- define "rdma-exporter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rdma-exporter.name" . }}
app.kubernetes.io/instance: {{ include "rdma-exporter.name" . }}
{{- end }}
