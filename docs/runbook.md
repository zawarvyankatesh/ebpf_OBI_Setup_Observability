# Runbook: every action, with commands

A log of what was done in this POC, in order, with the exact commands.
Learnings go in [phase-notes.md](phase-notes.md); this file is only "what we ran and how we checked it".

All commands run from the repo root in WSL, unless the step says **Windows**.

---

## Phase 0: Prerequisites & kernel check (2026-11-23)

### 0.1 Check tools and resources
```bash
for t in docker kind kubectl helm node python3 go jq k9s; do
  printf "%-8s " $t; command -v $t >/dev/null && ($t --version 2>/dev/null || $t version --client 2>/dev/null) | head -1 || echo MISSING
done
nproc; free -h
docker info --format '{{.OperatingSystem}} | CPUs={{.NCPU}} | Mem={{.MemTotal}}'
```
Result: Docker 29.6.2 (Docker Desktop on WSL2), kind v0.33.0-alpha, kubectl v1.36.3, helm v3.21.3, node v24, python 3.12, jq 1.7. **Go and k9s missing** (Go not needed: we build Go inside Docker). 8 CPUs.

### 0.2 Check the kernel that kind/OBI will use
kind nodes run inside Docker Desktop's VM, so check the kernel from a privileged container:
```bash
docker run --rm --privileged alpine:3.20 sh -c '
  uname -r
  ls -l /sys/kernel/btf/vmlinux
  mount -t securityfs none /sys/kernel/security 2>/dev/null
  cat /sys/kernel/security/lockdown'
```
Result: kernel `6.18.33.2-microsoft-standard-WSL2`, BTF present, lockdown file absent (= no lockdown).
**Verdict: OBI can run here.**

---

## RAM fix (2026-11-23)

### R.1 Find what uses memory
```bash
free -h
docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}'
kind get clusters
```
Result: 3 old kind clusters (`k8s-live-demo`, `mindstix-assignment-cluster`, `kind`) used ~5 GB. Only 2.6 GB free, swap 75% used.

### R.2 Remove old clusters (done by user)
```bash
kind delete cluster --name k8s-live-demo
kind delete cluster --name mindstix-assignment-cluster
kind delete cluster --name kind
```

### R.3 Raise WSL memory limit 8 GB → 9 GB
Created `C:\Users\USER\.wslconfig` (from WSL):
```bash
printf '[wsl2]\r\nmemory=9GB\r\n' > /mnt/c/Users/USER/.wslconfig
```
Applied it (**Windows**): quit Docker Desktop, then in PowerShell:
```powershell
wsl --shutdown
```
Then start Docker Desktop again.

### R.4 Verify
```bash
free -h                                   # total 8.7Gi, available ~5.9Gi
docker info --format '{{.MemTotal}}'      # ~9.37e9 bytes
```

---

## Phase 1: kind cluster (2026-11-23)

### 1.1 Pin the node image
The node image was already local (untagged). Get its digest:
```bash
docker images kindest/node --digests
```
→ `sha256:3489c767…` = `kindest/node:v1.36.1`. Pinned as `tag@digest` in `kind/kind-config.yaml`.

### 1.2 Write config + Makefile
- `kind/kind-config.yaml`: cluster `obi-poc`, 1 control-plane + 2 workers, port maps `127.0.0.1:3000 → 30300` (Grafana), `127.0.0.1:8080 → 30080` (frontend).
- `Makefile`: `cluster`, `nodes`, `clean`.

### 1.3 Create the cluster
```bash
make cluster      # = kind create cluster --config kind/kind-config.yaml --wait 120s
```

### 1.4 Verify (and prove the nodes share one kernel)
```bash
kubectl get nodes -o wide
uname -r
for n in obi-poc-control-plane obi-poc-worker obi-poc-worker2; do
  echo "$n: $(docker exec $n uname -r)"
  docker exec $n sh -c 'test -r /sys/kernel/btf/vmlinux && echo btf=yes'
  docker exec $n sh -c 'ls /sys/kernel/tracing/available_events >/dev/null && echo tracefs=yes'
  docker exec $n stat -fc %T /sys/fs/cgroup        # cgroup2fs
done
docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}'
```
Result: 3 nodes Ready; same kernel everywhere; BTF + tracefs + cgroup v2 inside nodes. Empty cluster ≈ 1.07 GB RAM.

### 1.5 Commit
```bash
git add CLAUDE.md Makefile kind/kind-config.yaml
git commit -m "Phase 1: kind cluster obi-poc (1 control-plane + 2 workers)"
```

---

## Phase 2: microservices (no observability code)

### 2.1 payments (Python / Flask)
Files: `apps/payments/{app.py,requirements.txt,Dockerfile}`.
- `POST /pay`, `/health`. Env `DELAY_MS_MAX` (default 50), `ERROR_RATE` (default 0.02).
- flask 3.1.3, gunicorn 27.0.1 (1 worker), base `python:3.13.18-slim`, user 10001.

Check latest versions before pinning:
```bash
pip index versions flask
pip index versions gunicorn
```
Build + test:
```bash
docker build -t shop/payments:0.1.0 apps/payments
docker run -d --rm --name payments-test -p 5000:5000 -e ERROR_RATE=0.3 shop/payments:0.1.0
curl -s localhost:5000/health
curl -s -X POST localhost:5000/pay -H 'content-type: application/json' -d '{"order_id":1,"amount":99.5}'
for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code} ' -X POST localhost:5000/pay \
  -H 'content-type: application/json' -d '{"order_id":1,"amount":1}'; done   # ~30% are 500
docker exec payments-test id -u      # 10001
docker stop payments-test
```

### 2.2 inventory (Go / net/http + Redis)
Files: `apps/inventory/{main.go,go.mod,go.sum,Dockerfile}`.
- `GET /health`, `GET /items`, `GET /items/{id}`, `POST /reserve {"item","qty"}` (409 if not enough), `POST /restock`.
- Stock lives in Redis keys `stock:<item>`, seeded at startup (`SETNX`).
- Env `PORT` (8080), `REDIS_ADDR` (`redis:6379`).
- Build `golang:1.27.4-alpine`, runtime `scratch`, user 65532. **Not stripped** (OBI's Go uprobes need symbols).

Check latest versions before pinning:
```bash
curl -s https://proxy.golang.org/github.com/redis/go-redis/v9/@latest            # v9.23.0
curl -s 'https://hub.docker.com/v2/repositories/library/golang/tags?page_size=100&name=alpine&ordering=last_updated' | jq -r '.results[].name'   # 1.27.4-alpine
curl -s 'https://hub.docker.com/v2/repositories/library/redis/tags?page_size=100&name=alpine&ordering=last_updated' | jq -r '.results[].name'    # 8.10.3-alpine
```
Create go.mod/go.sum without local Go:
```bash
cd apps/inventory
docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -e GOCACHE=/tmp/gocache -e GOPATH=/tmp/gopath \
  -v "$PWD":/src -w /src golang:1.27.4-alpine \
  sh -c 'go mod init shop/inventory && go get github.com/redis/go-redis/v9@v9.23.0 && go mod tidy && go vet ./...'
cd -
```
Build + test with Redis on a temp network:
```bash
docker build -t shop/inventory:0.1.0 apps/inventory          # 19.6 MB
docker network create shop-test
docker run -d --rm --name redis --network shop-test redis:8.10.3-alpine \
  redis-server --save '' --appendonly no --maxmemory 32mb
docker run -d --rm --name inventory --network shop-test -p 8081:8080 shop/inventory:0.1.0
curl -s localhost:8081/health
curl -s localhost:8081/items
curl -s localhost:8081/items/apple
curl -s -w ' [%{http_code}]\n' localhost:8081/items/mango                              # 404
curl -s -X POST localhost:8081/reserve -d '{"item":"apple","qty":30}'                   # left 70
curl -s -w ' [%{http_code}]\n' -X POST localhost:8081/reserve -d '{"item":"apple","qty":500}'   # 409
curl -s -X POST localhost:8081/restock
docker stats --no-stream inventory redis       # ~2.6 MB + ~5.7 MB
docker rm -f inventory redis; docker network rm shop-test
```
Check Go symbols are present (what OBI uprobes attach to):
```bash
id=$(docker create shop/inventory:0.1.0); docker cp $id:/inventory /tmp/inv.bin; docker rm $id
docker run --rm -v /tmp/inv.bin:/b:ro golang:1.27.4-alpine go tool nm /b | grep -E 'serverHandler.ServeHTTP|go-redis.*pool.*Conn.*Write'
```

### 2.3 orders (Python / FastAPI + Postgres)
Files: `apps/orders/{main.py,requirements.txt,Dockerfile}`.
- `POST /orders {"item","qty"}`: inventory `/reserve` → insert row `pending` → payments `/pay` → update `paid` / `payment_failed` (502).
- `GET /orders?limit=10`, `GET /health`, `GET /docs` (Swagger UI).
- Sync `def` handlers (thread pool), 1 uvicorn worker. Table created at startup (waits for Postgres).
- fastapi 0.165.0, uvicorn 0.54.0, httpx 0.28.1, psycopg[binary] 3.3.9, psycopg-pool 3.3.3.

### 2.4 frontend (Node.js / Express)
Files: `apps/frontend/{server.js,package.json,package-lock.json,Dockerfile}`.
- `GET /` HTML page; `GET /api/items`, `POST /api/restock` → inventory; `GET|POST /api/orders` → orders.
- express 5.3.0, `node:24.22.3-alpine`, user 1000, built-in `fetch`.
```bash
cd apps/frontend && npm install --package-lock-only && cd -    # creates package-lock.json for npm ci
```

### 2.5 loadgen (curl loop)
Files: `apps/loadgen/{loadgen.sh,Dockerfile}`, base `curlimages/curl:8.23.0`, user 100.
- Each loop: `GET /api/items` + `POST /api/orders` (random item, qty 1..3); restock every 100 loops. Env `TARGET`, `SLEEP`.
- 0.1.1: fixed item/qty using the same random number. 0.1.2: `trap` SIGTERM (PID 1 ignores it otherwise → 30 s shutdown; now 2 s).

Versions checked with:
```bash
for p in fastapi uvicorn httpx psycopg psycopg-pool; do pip index versions $p | head -1; done
npm view express version
# Docker Hub tags: node 24.x alpine, postgres 18.x alpine, curlimages/curl
curl -s 'https://hub.docker.com/v2/repositories/library/node/tags?page_size=100&name=alpine&ordering=last_updated' | jq -r '.results[].name'
```

### 2.6 Build all images
```bash
make build       # docker build each apps/<name> with the tag in the Makefile
docker images 'shop/*'
```
Non-root check: k8s `runAsNonRoot` needs a **numeric** USER in the image, so frontend uses `USER 1000` and loadgen `USER 100`:
```bash
docker run --rm node:24.22.3-alpine id node                     # uid=1000
docker run --rm --entrypoint id curlimages/curl:8.23.0          # uid=100
```

---

## Phase 3: Helm chart `shop` (2026-11-23)

### 3.1 Chart
`helm/shop/`: `Chart.yaml`, `values.yaml`, `templates/_helpers.tpl` (shared Deployment+Service template),
one-line files per app (`frontend|orders|inventory|payments|loadgen.yaml`), `postgres.yaml` (Secret + Deployment + Service, emptyDir),
`redis.yaml` (no persistence, maxmemory 32mb).
- Placement via `nodeSelector`: worker = frontend, inventory, payments; worker2 = orders, postgres, redis, loadgen.
- Every container has requests/limits; apps `runAsNonRoot`, drop all capabilities.
- Probes: startup (up to 3 min) + readiness + liveness on `/health`.
```bash
helm lint helm/shop
helm template shop helm/shop -n shop | kubectl apply --dry-run=server -f -
```

### 3.2 Load images into kind
```bash
make load        # kind load docker-image <img> --name obi-poc, for each shop/* image
docker exec obi-poc-worker crictl images | grep shop/
```
Note: `kind load` **fails for postgres/redis** (multi-arch official images: `content digest ... not found`).
Not needed: nodes pull them from Docker Hub.

### 3.3 Deploy
```bash
make deploy      # helm upgrade --install shop ./helm/shop -n shop --create-namespace --wait
kubectl -n shop get pods -o wide
```
Problem seen on first install: inventory + orders restarted once. Cause: Redis/Postgres image pull took ~72 s,
apps were still waiting for them (no HTTP server yet) → liveness probe killed them. Fix: `startupProbe` in `_helpers.tpl`.
How it was debugged:
```bash
kubectl -n shop get pod -l app.kubernetes.io/name=orders -o jsonpath='{.items[0].status.containerStatuses[0].lastState}'
kubectl -n shop logs deploy/orders --previous
kubectl -n shop get events --sort-by=.lastTimestamp
```

### 3.4 Verify end to end
```bash
kubectl -n shop logs deploy/loadgen --tail=5                     # items=200 order(...)=200
curl -s localhost:8080/api/items                                 # via kind NodePort mapping
curl -s -X POST localhost:8080/api/orders -H 'content-type: application/json' -d '{"item":"cherry","qty":2}'
kubectl -n shop exec deploy/postgres -- psql -U shop -d shop -tAc "select status, count(*) from orders group by status"
docker stats --no-stream                                         # control-plane ~1.2 GB, workers ~0.5 GB each
```

### 3.5 Explore with port-forward
```bash
kubectl -n shop port-forward svc/frontend  3000:3000     # http://localhost:3000        (UI)
kubectl -n shop port-forward svc/orders    8000:8000     # http://localhost:8000/docs   (Swagger)
kubectl -n shop port-forward svc/inventory 8081:8080     # http://localhost:8081/items
kubectl -n shop port-forward svc/payments  5000:5000     # curl -X POST localhost:5000/pay ...
```

---

## App change: admin area + robot customer switch (2026-11-23)

Why: Restock was public (anyone could call it), and there was no way to pause loadgen from the UI.

### What changed
- **frontend 0.2.1**
  - `/` customer page: stock, Buy, recent orders, robot status. **No restock button.**
  - `/admin/` admin page (**HTTP Basic Auth**): Start/Stop robot customer, Restock.
  - `GET /api/robot` (public, loadgen reads it), `POST /admin/api/robot {"enabled":bool}`, `POST /admin/api/restock` (login needed).
  - Old `POST /api/restock` removed (now 404).
  - Robot switch is kept in memory: a frontend restart resets it to `ROBOT_ENABLED` (default `true`).
  - 0.2.0 had a redirect loop on `/admin/` (Express 5 matches `/admin` and `/admin/` the same) → fixed in 0.2.1.
- **loadgen 0.2.0**: checks `GET /api/robot` every 5th loop (every 5 s when paused); restock uses admin login.
- **Helm chart 0.2.0**: Secret `shop-admin` (random 16-char password on first install, kept on upgrades via `lookup`; override with `--set admin.password=...`). `NOTES.txt` prints how to get it.

### Commands
```bash
make build && make load && make deploy

# admin password
kubectl -n shop get secret shop-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

### Verify
```bash
PW=$(kubectl -n shop get secret shop-admin -o jsonpath='{.data.password}' | base64 -d); U=http://localhost:8080
curl -s -o /dev/null -w '%{http_code}\n' -X POST $U/api/restock            # 404 (removed)
curl -s -o /dev/null -w '%{http_code}\n' $U/admin/                          # 401
curl -s -o /dev/null -w '%{http_code}\n' -u admin:wrong $U/admin/           # 401
curl -s -o /dev/null -w '%{http_code}\n' -u admin:$PW $U/admin/             # 200

# stop / start the robot customer
curl -s -u admin:$PW -X POST $U/admin/api/robot -H 'content-type: application/json' -d '{"enabled":false}'
kubectl -n shop logs deploy/loadgen --tail=3        # "paused by admin" within ~5 s
curl -s -u admin:$PW -X POST $U/admin/api/robot -H 'content-type: application/json' -d '{"enabled":true}'
kubectl -n shop logs deploy/loadgen --tail=3        # "resumed by admin"
```
Note: `inventory` `/restock` itself has no auth; it is only reachable inside the cluster. A NetworkPolicy would lock it down (not done, POC).

---

## Phase 4: Observability backend (2026-11-23)

### 4.1 Check current charts (not memory)
```bash
make obs-repos     # prometheus-community, grafana-community, open-telemetry
helm search repo -l prometheus-community/kube-prometheus-stack | head -3   # 93.9.0 (Prometheus v3.16.0, Grafana 13.3.1)
helm search repo tempo                                                    # grafana-community/tempo 3.2.1 (Tempo 3.1.1)
helm search repo open-telemetry/opentelemetry-collector                   # 0.182.0 (Collector 0.165.0)
```
Findings:
- **Tempo chart moved** from `grafana/tempo` (stuck at Tempo 2.9.0) to **`grafana-community/tempo`** (official notice: updates only there after 2026-01-30).
- Prometheus 3.x has a **native OTLP receiver** (`--web.enable-otlp-receiver`, path `/api/v1/otlp/v1/metrics`); chart key `prometheus.prometheusSpec.enableOTLPReceiver`.
- Collector 0.165.0 renamed components: exporters **`otlp_grpc` / `otlp_http`** (old `otlp` / `otlphttp`), processor `k8s_attributes`.

Read chart values offline (`helm show values` hung once while downloading):
```bash
helm pull prometheus-community/kube-prometheus-stack --version 93.9.0 --untar -d /tmp/charts
helm pull grafana-community/tempo --version 3.2.1 --untar -d /tmp/charts
helm pull open-telemetry/opentelemetry-collector --version 0.182.0 --untar -d /tmp/charts
# component names straight from the binary:
docker run --rm otel/opentelemetry-collector-k8s:0.165.0 components
```

### 4.2 Values files
- `observability/values-kube-prometheus-stack.yaml`: lean (no Alertmanager, node-exporter, kube-state-metrics, default rules/dashboards, control-plane scrapes); keeps kubelet + cAdvisor; retention 6h / 1GB; scrape 30s; OTLP receiver + promoted resource attributes + 30m out-of-order window; Grafana NodePort 30300 + Tempo datasource.
- `observability/values-tempo.yaml`: Tempo 3.1.1 monolithic, retention 2h, emptyDir, metrics-generator off.
- `observability/values-otel-collector.yaml`: `otel/opentelemetry-collector-k8s:0.165.0`, Deployment, name `otel-collector`; traces → `otlp_grpc/tempo`, metrics → `otlp_http/prometheus`; logs pipeline removed.

Validate before install:
```bash
helm template kps /tmp/charts/kube-prometheus-stack -n observability -f observability/values-kube-prometheus-stack.yaml > /tmp/kps.yaml
helm template tempo /tmp/charts/tempo -n observability -f observability/values-tempo.yaml > /tmp/tempo.yaml
helm template otel-collector /tmp/charts/opentelemetry-collector -n observability -f observability/values-otel-collector.yaml > /tmp/otel.yaml
# validate the rendered collector config with the real binary:
python3 -c 'import yaml;[open("/tmp/relay.yaml","w").write(d["data"]["relay"]) for d in yaml.safe_load_all(open("/tmp/otel.yaml")) if d and d["kind"]=="ConfigMap"]'
docker run --rm -e MY_POD_IP=127.0.0.1 -v /tmp/relay.yaml:/c.yaml:ro otel/opentelemetry-collector-k8s:0.165.0 validate --config=/c.yaml
```
Gotcha: Tempo chart's Service template needs `tempo.receivers.jaeger` → `jaeger: null` breaks rendering, so the Jaeger receivers stay (idle).

### 4.3 Install
```bash
make obs           # kps -> tempo -> otel-collector (pinned versions, --wait)
make grafana-pass  # Grafana admin password (user admin)
```
Problem on first install: `kps` failed (`context deadline exceeded`):
- `grafana-sc-dashboard` / `grafana-sc-datasources` **OOMKilled** at 96Mi → limit 192Mi.
- Grafana killed by **liveness probe**: with cpu limit 300m, Grafana 13 needed >160 s to start (and ~240Mi RAM) → limits cpu 1000m / 512Mi.
Debug commands:
```bash
kubectl -n observability get pod -l app.kubernetes.io/name=grafana -o jsonpath='{range .status.containerStatuses[*]}{.name} {.lastState.terminated.reason}{"\n"}{end}'
kubectl -n observability logs deploy/kps-grafana -c grafana --previous --tail=15
kubectl -n observability get events --sort-by=.lastTimestamp | grep grafana
```
Image pulls were slow (~2–3 min each), so the first install took ~20 min.

### 4.4 Verify
```bash
GP=$(make -s grafana-pass)
curl -s -u admin:$GP localhost:3000/api/health
curl -s -u admin:$GP localhost:3000/api/datasources/uid/prometheus/health    # "status":"OK"
curl -s -u admin:$GP localhost:3000/api/datasources/uid/tempo/health         # "status":"OK"

kubectl -n observability port-forward svc/kps-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/query --data-urlencode 'query=otelcol_process_memory_rss' | jq '.data.result[0].metric'   # arrived via OTLP
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health)"' | sort | uniq -c

# test span: must be sent from INSIDE the cluster (Collector listens on the pod IP, so port-forward to it fails)
TID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); SID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n'); NOW=$(date +%s%N)
kubectl -n shop exec deploy/loadgen -- curl -s -w '%{http_code}\n' http://otel-collector.observability:4318/v1/traces \
  -H 'content-type: application/json' -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"pipeline-test\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TID\",\"spanId\":\"$SID\",\"name\":\"hello-tempo\",\"kind\":2,\"startTimeUnixNano\":\"$((NOW-50000000))\",\"endTimeUnixNano\":\"$NOW\"}]}]}]}"
kubectl -n observability port-forward svc/tempo 3200:3200 &
curl -s localhost:3200/api/v2/traces/$TID | grep -o hello-tempo
```
Result: Grafana 13.3.1 OK, both datasources OK, Collector metrics in Prometheus with promoted labels, test span in Tempo, kubelet/cAdvisor targets up.
RAM after Phase 4: node containers ≈ 1.2 + 1.5 + 0.8 GB; ~3.8 GB still available.

---

## Phase 5: OBI (2026-11-23/24): observe only, least privilege

### 5.1 Check docs + chart + binary (not memory)
```bash
helm search repo open-telemetry | grep -i ebpf        # opentelemetry-ebpf-instrumentation 0.16.4 = OBI v1.0.0
helm pull open-telemetry/opentelemetry-ebpf-instrumentation --version 0.16.4 --untar -d /tmp/charts
grep -vE '^\s*#|^\s*$' /tmp/charts/opentelemetry-ebpf-instrumentation/values.yaml | head -80
helm template obi /tmp/charts/opentelemetry-ebpf-instrumentation -n observability | less     # see chart defaults
docker pull ghcr.io/open-telemetry/opentelemetry-ebpf-instrumentation/ebpf-instrument:v1.0.0
# learn exact Config v2 keys from the binary (docs page for export was down):
docker run --rm -v $PWD/tmp:/w ghcr.io/open-telemetry/opentelemetry-ebpf-instrumentation/ebpf-instrument:v1.0.0 config migrate --allow-partial /w/v1.yml
```
**Chart defaults are NOT safe for us** (must override):
- `privileged: true` → we use `privileged: false` (caps: BPF, PERFMON, SYS_PTRACE, CHECKPOINT_RESTORE, DAC_READ_SEARCH, NET_RAW).
- `contextPropagation.enabled: true` (adds hostNetwork, NET_ADMIN, cgroup + tracefs mounts) → `false`.
- default rules instrument **all namespaces** except a fixed list (contains `monitoring`, not our `observability`) → our rules: only `shop`.
- default exporters go to `${HOST_IP}:4317/4318` + a Prometheus pull port → our OTLP to `otel-collector.observability:4317`.
- Config v2 key for propagation: `extensions.obi.capture.engine.propagation.context_propagation: disabled`.

### 5.2 "Before" snapshot of the kernel
```bash
docker build -t local/bpftool:alpine3.20 tools/bpftool       # Alpine + bpftool, read-only use
make bpf-progs                                               # 133 programs: 116 cgroup_device (runc), 13 cgroup_skb, ...
docker run --rm --privileged alpine:3.20 dmesg > /tmp/dmesg-before.txt
```

### 5.3 Values + validation
`observability/values-obi.yaml`. Validate the rendered config with the OBI binary:
```bash
helm template obi /tmp/charts/opentelemetry-ebpf-instrumentation -n observability -f observability/values-obi.yaml > /tmp/obi.yaml
python3 -c 'import yaml;[open("/tmp/obi-config.yml","w").write(d["data"]["ebpf-instrument-config.yml"]) for d in yaml.safe_load_all(open("/tmp/obi.yaml")) if d and d["kind"]=="ConfigMap"]'
docker run --rm -v /tmp:/w ghcr.io/open-telemetry/opentelemetry-ebpf-instrumentation/ebpf-instrument:v1.0.0 config validate /w/obi-config.yml
grep -nE 'hostPID|hostNetwork|privileged|add:|- [A-Z_]+$|hostPath' /tmp/obi.yaml     # no hostNetwork, no hostPath, 6 caps
```

### 5.4 Install, then restart apps AFTER OBI
```bash
make obi                       # helm upgrade --install obi ... --version 0.16.4 -f observability/values-obi.yaml
#   (if GitHub download times out: helm upgrade --install obi /tmp/charts/opentelemetry-ebpf-instrumentation ...)
kubectl -n observability logs ds/obi-opentelemetry-ebpf-instrumentation | grep 'instrumenting process'
kubectl -n shop rollout restart deploy/frontend deploy/orders deploy/inventory deploy/payments deploy/loadgen
```
Don't restart redis/postgres: no persistence → stock/orders are wiped (inventory only seeds at startup → 409/500).
If that happens: admin Restock (`curl -u admin:$PW -X POST localhost:8080/admin/api/restock`).

Log warnings/errors seen (least-privilege side effects):
- `join target netns: operation not permitted` → can't scan sockets opened before OBI (needs SYS_ADMIN) → restart apps.
- `tracefs fallback failed` + Node.js `unable to capture stable node injection target` → Node.js runtime extras off (frontend).
- `creating bpffs otel path` → no `/sys/fs/bpf` mount, maps stay in-process (cleaner rollback).
- EC2 metadata timeout, cluster name → set `OTEL_EBPF_KUBE_CLUSTER_NAME=obi-poc`.

### 5.5 Verify data (zero code changes)
```bash
kubectl -n observability port-forward svc/kps-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/query --data-urlencode 'query=count by (__name__) ({k8s_namespace_name="shop"})' | jq -r '.data.result[].metric.__name__'
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (service_name, http_route, http_response_status_code) (rate(http_server_request_duration_seconds_count{k8s_namespace_name="shop"}[2m]))'
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (service_name, db_system_name, db_operation_name) (db_client_operation_duration_seconds_count{k8s_namespace_name="shop"})'
kubectl -n observability port-forward svc/tempo 3200:3200 &
curl -s -G localhost:3200/api/search --data-urlencode 'q={resource.service.name="frontend" && name="GET /api/items"}' --data-urlencode limit=1
```
Note: right after a restart `rate()` looks wrong (new series, only 1 sample at 15 s interval). Compare raw counters instead.

### 5.6 See the eBPF programs + rollback test
```bash
make bpf-progs                 # 501 programs after OBI (+398: 351 kprobe/uprobe, 6 socket_filter, 2 tracing, 2 tracepoint, + new pods' cgroup_device)
docker run --rm --privileged alpine:3.20 dmesg | tail -50     # no bpf/verifier/oops lines
make obi-uninstall             # helm uninstall obi
make bpf-progs                 # obi_* programs: 361 -> 0, total back to ~132
make obi && kubectl -n shop rollout restart deploy/frontend deploy/orders deploy/inventory deploy/payments deploy/loadgen
```
OBI memory: ~420 MiB on worker (Node+Go+Python), ~250 MiB on worker2 → limit raised to 768Mi.

---

## Phase 6: Dashboards & distributed traces (2026-11-24)

### 6.1 Service graph metrics from OBI (no extra component)
`observability/values-obi.yaml`: `capture.metrics.features: [application, application_service_graph]`
```bash
helm upgrade obi <chart> -n observability -f observability/values-obi.yaml --wait
kubectl -n shop rollout restart deploy/frontend deploy/orders deploy/inventory deploy/payments deploy/loadgen
# Prometheus: traces_service_graph_request_total{client, server, connection_type}, _failed_total, _server_seconds, _client_seconds
curl -s localhost:9090/api/v1/query --data-urlencode 'query=sum by (client, server) (traces_service_graph_request_total)'
```
Edges seen: loadgen→frontend, frontend→orders/inventory, orders→inventory/payments/postgres, inventory→redis.
`incoming → X` = kubelet health checks; `obi-poc-control-plane → frontend` = curl from laptop via NodePort.

### 6.2 Grafana dashboard "Shop: RED (OBI, zero-code)"
File `observability/dashboards/shop-red.json` (uid `shop-red-obi`), loaded by the Grafana sidecar from a ConfigMap labelled `grafana_dashboard=1`:
```bash
make dashboards
```
Panels: service map (Tempo serviceMap, drawn in the browser), edges table, req/s, error % (5xx), p95, p50/p95/p99 for `$service`, req/s by status, RED table per route, DB ops/s + DB p95.
Check every panel returns data (Grafana query API):
```bash
curl -s -u admin:$(make -s grafana-pass) localhost:3000/api/dashboards/uid/shop-red-obi | jq '.dashboard.panels[].title'
# POST /api/ds/query with each panel target (Tempo serviceMap is browser-side: "unsupported query type" on the API is expected)
```
Fixes during build: p50 query broken by a text replace; error % showed "no data" with zero 5xx → `(errors or 0 * total) / total`.
