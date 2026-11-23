# OBI + eBPF observability POC on kind

Zero-code traces and metrics for a small microservices app, using **OBI** (OpenTelemetry eBPF Instrumentation), on a local **kind** cluster.

- Plan and context: [CLAUDE.md](CLAUDE.md)
- Every command we ran: [docs/runbook.md](docs/runbook.md)
- What we learned: [docs/phase-notes.md](docs/phase-notes.md)

## Status

| Phase | What | Status |
|---|---|---|
| 0 | Prerequisites, kernel check (BTF, lockdown) | done |
| 1 | kind cluster `obi-poc` (1 control-plane + 2 workers) | done |
| 2 | Microservices (no tracing code) | done |
| 3 | Helm chart `shop` | done |
| 4 | Prometheus, Grafana, Tempo, OTel Collector | next |
| 5 | OBI DaemonSet | |
| 6 | Dashboards, distributed traces, incidents | |

## The app

```
loadgen ─► frontend (Node) ─┬─► orders (Python/FastAPI) ─┬─► inventory (Go) ─► redis
                            │                            ├─► payments (Python/Flask)
                            │                            └─► postgres
                            └─► inventory (Go) ─► redis
```

| Node | Pods |
|---|---|
| obi-poc-worker | frontend, inventory, payments |
| obi-poc-worker2 | orders, postgres, redis, loadgen |

## Run it

```bash
make cluster     # kind cluster
make build       # docker images
make load        # copy images into kind
make deploy      # helm install shop
make status      # pods + loadgen output
```

Open the app: http://localhost:8080 (NodePort), or `make pf` → http://localhost:3000.

Explore single services:
```bash
kubectl -n shop port-forward svc/orders    8000:8000   # http://localhost:8000/docs
kubectl -n shop port-forward svc/inventory 8081:8080   # http://localhost:8081/items
kubectl -n shop port-forward svc/payments  5000:5000
```

Clean up: `make clean`.
