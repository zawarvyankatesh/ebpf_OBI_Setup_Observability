{{/*
Common labels. Input: dict "name" <svc name> "root" <$>
*/}}
{{- define "shop.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/part-of: shop
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ .root.Chart.Name }}-{{ .root.Chart.Version }}
{{- end }}

{{/*
One app = Deployment (+ Service if it has a port).
Input: dict "name" <svc name> "root" <$> "svc" <values for this svc>
*/}}
{{- define "shop.app" -}}
{{- $s := .svc -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  labels: {{- include "shop.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ .name }}
  template:
    metadata:
      labels: {{- include "shop.labels" . | nindent 8 }}
    spec:
      {{- with $s.node }}
      nodeSelector:
        kubernetes.io/hostname: {{ . }}
      {{- end }}
      securityContext:
        runAsNonRoot: true
      containers:
        - name: {{ .name }}
          image: {{ $s.image }}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          {{- if $s.port }}
          ports:
            - name: http
              containerPort: {{ $s.port }}
          # startupProbe: allow up to 3 min to start (apps wait for Redis/Postgres first).
          # Liveness/readiness only begin after it succeeds, so no early restarts.
          startupProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
            failureThreshold: 36
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 20
          {{- end }}
          env:
            {{- range $k, $v := $s.env }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
            {{- range $k, $v := $s.secretEnv }}
            - name: {{ $k }}
              valueFrom:
                secretKeyRef: { name: {{ $v.secret }}, key: {{ $v.key }} }
            {{- end }}
          resources: {{- toYaml $s.resources | nindent 12 }}
{{- if $s.port }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels: {{- include "shop.labels" . | nindent 4 }}
spec:
  type: {{ if $s.nodePort }}NodePort{{ else }}ClusterIP{{ end }}
  selector:
    app.kubernetes.io/name: {{ .name }}
  ports:
    - name: http
      port: {{ $s.port }}
      targetPort: http
      {{- with $s.nodePort }}
      nodePort: {{ . }}
      {{- end }}
{{- end }}
{{- end }}
