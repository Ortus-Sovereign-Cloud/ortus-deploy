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
{{- if eq .Values.files.mode "bundled" -}}{{ .Values.files.bundled.existingSecret | default (printf "%s-files" (include "ortus.name" .)) }}{{- else -}}{{ required "files.external.existingSecret is required when files.mode is external" .Values.files.external.existingSecret }}{{- end -}}
{{- end -}}
{{- define "ortus.s3Endpoint" -}}
{{- if eq .Values.files.mode "bundled" -}}http://{{ include "ortus.name" . }}-files:9000{{- else -}}{{ required "files.external.endpoint is required when files.mode is external" .Values.files.external.endpoint }}{{- end -}}
{{- end -}}

{{/* The settings every Ortus container gets. */}}
{{- define "ortus.env" -}}
- name: ORTUS_DATA_DIR
  value: /data
{{- with .Values.publicUrl }}
- name: ORTUS_PUBLIC_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
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
- name: ORTUS_SECRETS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ortus.secretsSecret" . }}
      key: key
{{- /* Restore points: in the files store, or one of their own. */}}
{{- if .Values.restorePoints.external.endpoint }}
- name: ORTUS_BACKUP_S3_ENDPOINT
  value: {{ .Values.restorePoints.external.endpoint | quote }}
- name: ORTUS_BACKUP_S3_BUCKET
  value: {{ required "restorePoints.external.bucket is required with an endpoint" .Values.restorePoints.external.bucket | quote }}
- name: ORTUS_BACKUP_S3_REGION
  value: {{ .Values.restorePoints.external.region | quote }}
- name: ORTUS_BACKUP_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ required "restorePoints.external.existingSecret is required with an endpoint" .Values.restorePoints.external.existingSecret }}
      key: access_key
- name: ORTUS_BACKUP_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.restorePoints.external.existingSecret }}
      key: secret_key
{{- else }}
- name: ORTUS_BACKUP_S3_ENDPOINT
  value: {{ include "ortus.s3Endpoint" . | quote }}
- name: ORTUS_BACKUP_S3_BUCKET
  value: {{ .Values.files.bucket | quote }}
- name: ORTUS_BACKUP_S3_REGION
  value: {{ .Values.files.region | quote }}
- name: ORTUS_BACKUP_S3_ROOT
  value: {{ .Values.restorePoints.root | quote }}
- name: ORTUS_BACKUP_S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ortus.s3Secret" . }}
      key: access_key
- name: ORTUS_BACKUP_S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "ortus.s3Secret" . }}
      key: secret_key
{{- end }}
{{- end -}}

{{/* The secret holding the master key that seals stored secrets. */}}
{{- define "ortus.secretsSecret" -}}
{{- .Values.secrets.existingSecret | default (printf "%s-secrets" (include "ortus.name" .)) -}}
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
