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
