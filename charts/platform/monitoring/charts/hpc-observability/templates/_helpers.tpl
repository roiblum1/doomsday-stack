{{/*
Full resource name prefix matching the live hpc-obs Helm release
(release "hpc-obs" + chart "hpc-observability"). Hard-coded so the
rendered objects match the cluster exactly when deployed as a subchart
of the monitoring umbrella, whose release name differs.
*/}}
{{- define "hpc-observability.fullname" -}}
hpc-obs-hpc-observability
{{- end }}

{{/*
Chart name and version as used by the chart label.
*/}}
{{- define "hpc-observability.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels matching the live hpc-obs release. The instance label is
hard-coded so Service/ServiceMonitor selectors keep matching regardless
of the umbrella release name.
*/}}
{{- define "hpc-observability.labels" -}}
app.kubernetes.io/name: hpc-observability
app.kubernetes.io/instance: hpc-obs
app.kubernetes.io/part-of: hpc-observability
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "hpc-observability.chart" . }}
{{- end }}

{{/*
Selector labels used by DaemonSet/Service/ServiceMonitor. Combine with
the hpc.observability/mode label (fabric|node) per resource.
*/}}
{{- define "hpc-observability.selectorLabels" -}}
app.kubernetes.io/name: hpc-observability
app.kubernetes.io/instance: hpc-obs
{{- end }}
