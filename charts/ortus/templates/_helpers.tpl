{{- define "ortus.name" -}}{{ .Release.Name | trunc 40 | trimSuffix "-" }}{{- end -}}

{{- define "ortus.labels" -}}
app.kubernetes.io/name: ortus
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "ortus.image" -}}{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}{{- end -}}

{{- define "ortus.dbSecret" -}}
{{- if eq .Values.database.mode "bundled" -}}{{ include "ortus.name" . }}-db-app{{- else -}}{{ required "database.external.existingSecret is required when database.mode is external" .Values.database.external.existingSecret }}{{- end -}}
{{- end -}}
{{- define "ortus.dbKey" -}}{{ if eq .Values.database.mode "bundled" }}uri{{ else }}{{ .Values.database.external.key }}{{ end }}{{- end -}}

{{- define "ortus.s3Secret" -}}
{{- if eq .Values.files.mode "bundled" -}}{{ include "ortus.name" . }}-files{{- else -}}{{ required "files.external.existingSecret is required when files.mode is external" .Values.files.external.existingSecret }}{{- end -}}
{{- end -}}
{{- define "ortus.s3Endpoint" -}}
{{- if eq .Values.files.mode "bundled" -}}http://{{ include "ortus.name" . }}-files:9000{{- else -}}{{ required "files.external.endpoint is required when files.mode is external" .Values.files.external.endpoint }}{{- end -}}
{{- end -}}

{{/* The settings every Ortus container gets. */}}
{{- define "ortus.env" -}}
- name: ORTUS_DATA_DIR
  value: /data
- name: ORTUS_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "ortus.dbSecret" . }}
      key: {{ include "ortus.dbKey" . }}
- name: ORTUS_DATABASE_MAX_CONNECTIONS
  value: {{ .Values.database.maxConnections | quote }}
- name: ORTUS_FILES_S3_ENDPOINT
  value: {{ include "ortus.s3Endpoint" . | quote }}
- name: ORTUS_FILES_S3_BUCKET
  value: {{ .Values.files.bucket | quote }}
- name: ORTUS_FILES_S3_REGION
  value: {{ .Values.files.region | quote }}
- name: ORTUS_FILES_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ortus.s3Secret" . }}
      key: access_key
- name: ORTUS_FILES_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ortus.s3Secret" . }}
      key: secret_key
{{- end -}}

{{- define "ortus.podSpecCommon" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets: {{ toYaml . | nindent 2 }}
{{- end }}
securityContext: {{ toYaml .Values.podSecurityContext | nindent 2 }}
automountServiceAccountToken: false
# Kubernetes would otherwise set ORTUS_WEB_PORT=tcp://... for the
# ortus-web Service, which is one of the program's own settings.
enableServiceLinks: false
{{- with .Values.nodeSelector }}
nodeSelector: {{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations: {{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity: {{ toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
