# Phase notes: what I learned

Short, simple notes per phase. Commands are in [runbook.md](runbook.md).

## Phase 0: Prerequisites & kernel check
- eBPF programs run in the **kernel**. On my laptop that is the **WSL2 VM kernel** (6.18), shared by Docker Desktop, kind nodes and every pod.
- **BTF** (`/sys/kernel/btf/vmlinux`) describes kernel structs, so OBI's one compiled eBPF binary can adapt to my kernel (**CO-RE**).
- **Lockdown** is off, so OBI may write `traceparent` into Go process memory (Go context propagation).
- RAM matters: old kind clusters used 5 GB. WSL limit raised to 9 GB (`.wslconfig`).

## Phase 1: kind cluster
- A kind node is a **container**. 3 nodes = 3 containers on **one kernel** (`uname -r` is the same everywhere).
- `hostPID: true` on kind = the **node container's** PID namespace, not the WSL VM. But kprobes fire **kernel-wide**. To check in Phase 5: does each OBI pod only report its own node's pods (no duplicate spans)?
- `extraPortMappings` + NodePort = how my browser reaches services (kind's version of a LoadBalancer).

## Phase 2: microservices (no tracing code)
| Service | Runtime | How OBI will see it |
|---|---|---|
| frontend | Node / Express | kprobes on sockets (HTTP server + outgoing `fetch`) |
| orders | Python / FastAPI | kprobes; also Postgres wire protocol (SQL spans) |
| inventory | Go / net/http | **uprobes** on Go functions in the binary + kprobes; Redis protocol |
| payments | Python / Flask | kprobes on sockets |
- Go binary is **not stripped**: uprobes find functions (`net/http.serverHandler.ServeHTTP`, go-redis `pool.(*Conn).Write`) by symbol name.
- Go drops unused code: inventory has no `http.Transport.roundTrip` because it never calls HTTP out.
- `payments` has knobs `DELAY_MS_MAX` and `ERROR_RATE` for incidents later.
- k8s `runAsNonRoot` needs a **numeric** `USER` in the image.
- A shell script as PID 1 ignores SIGTERM unless it uses `trap` → pod takes 30 s to stop.

## Phase 3: Helm chart
- One shared template (`_helpers.tpl`) → each service file is one line. Small and readable.
- Services are pinned to workers so most calls are **cross-node** (frontend→orders, orders→inventory/payments, inventory→redis); two stay same-node (frontend→inventory, orders→postgres). Good for comparing traces later.
- `startupProbe` protects slow starters from the liveness probe (we hit this: 72 s image pull of Redis/Postgres).
- `kind load docker-image` fails on multi-arch official images; nodes can just pull them.
- Whole app ≈ 0.25 GB RAM; cluster + app ≈ 2.2 GB.
- **We are blind right now**: the app works, but we have no metrics (except pod CPU/RAM), no traces, no idea which call is slow. Only logs. OBI will fix that without touching code.

## Phase 4: Observability backend
- Flow: (OBI) → **OTel Collector** → traces to **Tempo**, metrics to **Prometheus** → **Grafana** shows both.
- **Prometheus native OTLP receiver** (3.x): the Collector *pushes* OTLP to `/api/v1/otlp`. No scrape, no remote-write conversion. `promoteResourceAttributes` turns OTel resource attributes (`service.name`, `k8s.pod.name`…) into labels (`service_name`, `k8s_pod_name`), so PromQL can filter by service.
- Push needs `outOfOrderTimeWindow` (late samples are normal with push).
- Things move fast: Tempo's chart changed repo (grafana-community), Collector components were renamed (`otlp_grpc`, `otlp_http`). Always check, never trust memory.
- Resource limits are a **ceiling**, requests are the **reservation**. Too-low CPU limit = slow start = liveness probe kills it (Grafana). Too-low memory limit = OOMKilled (sidecars).
- The Collector listens on the **pod IP**, so `kubectl port-forward` to it fails; test from inside the cluster.
- Helm merges maps; `key: null` removes a default (works for the Collector, broke Tempo's chart).
- Checkpoint state: Grafana works, datasources green, **no app data yet**. The shop is still a black box.

## Phase 5: OBI (observe only)
- **Chart defaults ≠ OBI defaults.** OBI keeps context propagation off by default, but the Helm chart sets `contextPropagation.enabled: true` and `privileged: true`. Always render and read before installing.
- Least privilege works for RED + spans: BPF, PERFMON, SYS_PTRACE, CHECKPOINT_RESTORE, DAC_READ_SEARCH, NET_RAW. Side effects: can't see sockets opened before OBI (no SYS_ADMIN for `setns`) → restart apps; Node.js extras off.
- **One OBI per node only instruments its node's processes** (hostPID = node container's PID namespace), even though kprobes are kernel-wide. No duplicate spans on kind.
- Zero code changes gave: HTTP server/client RED metrics, **SQL spans** (Postgres wire protocol), **Redis spans** (RESP), DNS lookups, all with k8s labels.
- **Same node → joined trace, cross node → split trace** (propagation off). OBI's "black-box" correlation matches client + server of the same TCP connection when ONE OBI instance sees both ends. Across nodes, the trace id must travel in the request → context propagation (Phase 6).
- Go (inventory): full in-process trace (server → in queue → processing → Redis), thanks to uprobes on Go functions/goroutines.
- Python FastAPI (orders): every span is its own trace. The asyncio loop → threadpool hop breaks OBI's Python context tracking. Gunicorn (payments) is fine.
- bpftool: 133 programs before (116 are runc `cgroup_device` = every container already uses eBPF), +~360 `obi_*` programs; uprobes show as type `kprobe`. ~318k instructions passed the verifier. No kernel log errors.
- **Rollback is clean:** `helm uninstall` → process exits → kernel removes all `obi_*` programs (nothing pinned in bpffs).
- `rate()` on brand-new series lies for a minute; compare raw counters.
- App weakness found: inventory seeds Redis only at startup; Redis has no persistence → restarting Redis = empty stock.
