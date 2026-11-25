{{- define "mlflow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name of the release resources. With the release name "mlflow", it is "mlflow".
*/}}
{{- define "mlflow.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mlflow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mlflow.labels" -}}
helm.sh/chart: {{ include "mlflow.chart" . }}
{{ include "mlflow.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mlflow
{{- end }}

{{- define "mlflow.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mlflow.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mlflow.postgresql.fullname" -}}
{{- printf "%s-postgresql" (include "mlflow.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mlflow.moto.fullname" -}}
{{- printf "%s-moto" (include "mlflow.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mlflow.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mlflow.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "mlflow.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{- define "mlflow.db.host" -}}
{{- if .Values.postgresql.enabled }}
{{- include "mlflow.postgresql.fullname" . }}
{{- else }}
{{- required "externalDatabase.host is required when postgresql.enabled is false" .Values.externalDatabase.host }}
{{- end }}
{{- end }}

{{- define "mlflow.db.port" -}}
{{- if .Values.postgresql.enabled }}
{{- .Values.postgresql.port }}
{{- else }}
{{- .Values.externalDatabase.port }}
{{- end }}
{{- end }}

{{- define "mlflow.db.database" -}}
{{- if .Values.postgresql.enabled }}
{{- .Values.postgresql.auth.database }}
{{- else }}
{{- .Values.externalDatabase.database }}
{{- end }}
{{- end }}

{{- define "mlflow.db.username" -}}
{{- if .Values.postgresql.enabled }}
{{- .Values.postgresql.auth.username }}
{{- else }}
{{- .Values.externalDatabase.username }}
{{- end }}
{{- end }}

{{- define "mlflow.db.secretName" -}}
{{- if .Values.postgresql.enabled }}
{{- required "postgresql.auth.existingSecret is required: create the Secret with kubectl first (see docs/local.md)" .Values.postgresql.auth.existingSecret }}
{{- else }}
{{- required "externalDatabase.existingSecret is required when postgresql.enabled is false" .Values.externalDatabase.existingSecret }}
{{- end }}
{{- end }}

{{- define "mlflow.db.passwordKey" -}}
{{- if .Values.postgresql.enabled }}
{{- .Values.postgresql.auth.passwordKey }}
{{- else }}
{{- .Values.externalDatabase.passwordKey }}
{{- end }}
{{- end }}

{{- define "mlflow.s3.secretName" -}}
{{- required "s3.existingSecret is required: create the Secret with kubectl first (see docs/local.md)" .Values.s3.existingSecret }}
{{- end }}

{{- define "mlflow.s3.endpointUrl" -}}
{{- if .Values.s3.endpointUrl }}
{{- .Values.s3.endpointUrl }}
{{- else if .Values.moto.enabled }}
{{- printf "http://%s:%v" (include "mlflow.moto.fullname" .) .Values.moto.port }}
{{- end }}
{{- end }}

{{/*
Bucket name from artifacts.destination ("s3://<bucket>/<prefix>").
*/}}
{{- define "mlflow.s3.bucket" -}}
{{- $dest := .Values.artifacts.destination }}
{{- if not (hasPrefix "s3://" $dest) }}
{{- fail "artifacts.destination must start with s3://" }}
{{- end }}
{{- regexReplaceAll "^s3://([^/]+).*$" $dest "${1}" }}
{{- end }}

{{/*
Value of MLFLOW_SERVER_ALLOWED_HOSTS. It replaces the MLflow defaults. It keeps their IPv4
localhost names and private IP ranges, and leaves out [::1], 0.0.0.0, fc00:* and fd00:*.
*/}}
{{- define "mlflow.allowedHosts" -}}
{{- $name := include "mlflow.fullname" . }}
{{- $ns := .Release.Namespace }}
{{- $hosts := list "localhost" "localhost:*" "127.0.0.1" "127.0.0.1:*" }}
{{- range $dns := list $name (printf "%s.%s" $name $ns) (printf "%s.%s.svc" $name $ns) (printf "%s.%s.svc.cluster.local" $name $ns) }}
{{- $hosts = append $hosts $dns }}
{{- $hosts = append $hosts (printf "%s:*" $dns) }}
{{- end }}
{{- $hosts = concat $hosts (list "10.*" "192.168.*") }}
{{- range $i := untilStep 16 32 1 }}
{{- $hosts = append $hosts (printf "172.%d.*" $i) }}
{{- end }}
{{- if and .Values.ingress.enabled .Values.ingress.host }}
{{- $hosts = append $hosts .Values.ingress.host }}
{{- end }}
{{- $hosts = concat $hosts .Values.mlflow.allowedHosts }}
{{- join "," $hosts }}
{{- end }}

{{/*
Value of MLFLOW_SERVER_CORS_ALLOWED_ORIGINS. MLflow always allows the localhost origins.
*/}}
{{- define "mlflow.corsAllowedOrigins" -}}
{{- $origins := list }}
{{- if and .Values.ingress.enabled .Values.ingress.host }}
{{- $origins = list (printf "http://%s" .Values.ingress.host) (printf "https://%s" .Values.ingress.host) }}
{{- end }}
{{- $origins = concat $origins .Values.mlflow.corsAllowedOrigins }}
{{- join "," $origins }}
{{- end }}
