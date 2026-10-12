{{/* Fullname: release-qualified prefix for all names. */}}
{{- define "glm53.fullname" -}}
{{- if .Values.nameOverride -}}
{{- .Values.nameOverride -}}
{{- else -}}
{{- .Release.Name -}}
{{- end -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "glm53.labels" -}}
app.kubernetes.io/name: {{ include "glm53.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* model.uri pvc://<claim>/<subPath> derived from storage + model values. */}}
{{- define "glm53.modelUri" -}}
pvc://{{ .Values.storage.models.pvcName }}/{{ .Values.model.subPath }}
{{- end -}}

{{/* nodeAffinity block for the static local PVs (shared by both). */}}
{{- define "glm53.pvNodeAffinity" -}}
nodeAffinity:
  required:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
{{ toYaml .Values.nodes.hostnames | indent 14 }}
{{- end -}}
