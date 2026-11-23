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
