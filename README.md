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
| 4 | Prometheus, Grafana, Tempo, OTel Collector | done |
| 5 | OBI DaemonSet (observe only, least privilege) | done |
| 6 | Dashboards, distributed traces (propagation, SYS_ADMIN lab only), incident demo | done |

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

Observability (Phase 4):
```bash
make obs-repos && make obs      # Prometheus + Grafana, Tempo, OTel Collector
make grafana-pass               # Grafana password (user: admin)
```
Grafana: http://localhost:3000

OBI (Phase 5):
```bash
make obi            # install/upgrade OBI (unprivileged, no context propagation, ns shop only)
make bpf-progs      # count eBPF programs in the shared kernel
make obi-uninstall  # remove OBI (programs are removed from the kernel)
```
Always restart app pods after (re)installing OBI.

Dashboards (Phase 6): `make dashboards` → http://localhost:3000/d/shop-red-obi

Incident demo:
```bash
helm upgrade shop ./helm/shop -n shop --reuse-values --set-string payments.env.DELAY_MS_MAX=1500 --set-string payments.env.ERROR_RATE=0.25
make deploy   # back to normal (uses --reset-values)
```

Clean up: `make clean`.
