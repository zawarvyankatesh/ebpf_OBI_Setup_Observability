# Plan for review: next steps (NOT executed yet)

Status: **draft for review**. Nothing in this file has been applied to the cluster, the apps or OBI.
Legend: ✅ seen in this POC · 📄 documented by OBI/W3C (source below) · 🔬 not verified, needs a lab test · ❓ needs your decision.

Goals you gave:
1. Know which **trace** belongs to which **order id**, without guessing by time.
2. Later: **one trace per order** for the whole journey.
3. Keep **Node.js frontend**; give OBI the permissions it needs.
4. Understand short-lived processes, internal-function visibility, and CNI.
5. **Fault-injection scripts** that change a ConfigMap; pods follow it **without restart**.

---

## Part A: Explanations (research results)

### A1. How a trace id is made 📄

W3C Trace Context (the `traceparent` HTTP header):

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  trace-id: 16 bytes = 32 hex      parent span-id:  flags (01 = sampled)
             version                             8 bytes = 16 hex
```

- **trace-id**: one id for the whole journey. All zeros is invalid. It's meant to be **random / globally unique**.
  Level 2 of the spec adds a "random" flag: at least the **right-most 7 bytes must be random** when that flag is set (W3C Trace Context Level 2, Candidate Recommendation).
- **span-id**: one id per step (span).
- **Who creates it here:** OBI. "If OBI can't find incoming context, it generates one according to the W3C specification" (OBI docs, distributed-traces). *Where* (kernel or user space) and the random source are **not documented**.
- **OBI respects an id the app already set:** "If an application already added traceparent, OBI uses that value instead of its own." It must be inside the **first 4 KiB** of the request (plaintext injector), otherwise you end up with two headers (OBI devdocs, context-propagation).

How it flows in our app **today**:

```
loadgen (curl, no header)
  → frontend SERVER span: OBI generates trace-id T
  → frontend CLIENT span (only if Node in-process link works)
  → OBI writes "traceparent: 00-T-<client span>-01" into frontend's outgoing request (sk_msg)
  → orders SERVER span reads it → same trace T
  → orders' outgoing calls get T again → inventory, payments
```

### A2. Can the trace id contain the order id (as a suffix)? Brainstorm

**Problem:** the trace starts (at loadgen/frontend) **before** the order id exists. Postgres creates `3051` during the `INSERT`, in the middle of the trace. So with today's numeric ids we **cannot** put the order id inside the trace id.

| Idea | How | Verdict |
|---|---|---|
| 1. **Store the mapping** (recommended) | `orders` reads the incoming `traceparent` header (already injected by OBI), saves `trace_id` in the `orders` row, logs `order_id=3051 trace_id=…`, returns `trace_id` in the API response | ✅ simple, exact. Small app change (reading a header is **not** tracing code: no SDK, no spans) |
| 2. OBI **log enricher** adds `trace_id` to app logs | app logs `order created order_id=3051`, OBI appends ` trace_id=… span_id=…` | 📄 exists in OBI (see A3). Zero code. Needs SYS_ADMIN, a bpffs mount, and **working in-process context** |
| 3. Client pre-generates the reference | the client creates an order reference **before** calling (e.g. UUIDv7, 16 bytes, time-sortable with a random tail) and sends it as the trace-id in `traceparent`; orders stores it as `order_ref` | 🔬 elegant ("order ref = trace id"), but the app now sets tracing headers itself, and the random-bits rules (A1) must hold. Brainstorm only |
| 4. Put the order id in the trace-id bits | e.g. `…0000000000000bed` (3051 in hex) | ❌ order id unknown at trace start; breaks the "random" expectation used by sampling |

**Recommendation:** idea 1 now (exact and cheap). Try idea 2 next to it as an experiment, to compare "zero-code logs" with "one line of app code".

### A3. OBI log enricher (trace-log correlation) 📄

- What it does: OBI **rewrites the app's log lines** (stdout, stderr, pipe, tty) and adds `trace_id`/`span_id` while a span is active. JSON logs get keys; plain text gets `key=value` (placement `suffix` by default).
- How (devdocs): it hooks `write`/`writev`, copies the line, **overwrites the original buffer with zeros** (`bpf_probe_write_user`), and re-emits the enriched line. The container log keeps a NUL placeholder line (filter regex `^[\x00\s]*$`).
- Config v2 (verified with our OBI binary):
  ```yaml
  extensions.obi.correlation.log_trace_annotation:
    enabled: true
    field_names: { trace_id: trace_id, span_id: span_id }
    plain_text: { enabled: true, placement: suffix, multiline: first_line }
  ```
- Needs: CAP_SYS_ADMIN (✅ we have it, lab only), **bpffs mounted at `/sys/fs/bpf`** (❌ not mounted today), kernel 6.0+ (✅ 6.18), Python `PYTHONUNBUFFERED=1`.
- Limits: first 8 KiB of a write; only **while a span is active on that thread**. That means it won't work where in-process tracking fails (today: FastAPI `orders`, Node `frontend`).
- ⚠️ Pinned maps in bpffs **stay after OBI exits**. The rollback must also delete `/sys/fs/bpf/otel` (🔬 check the exact path).

### A4. The Node.js issue, and "give OBI all permissions" 📄/🔬

- 📄 OBI uses **Node.js async hooks** in a small injected agent. The agent is injected via **SIGUSR1** (opens Node's inspector). Supported Node 12.17+ (we run 24 ✅). An app's own SIGUSR1 handler interferes (our frontend has none ✅).
- 📄 Config v2: `capture.runtimes.nodejs.enabled: true` (already the default, ✅ seen in our config dump).
- 🔬 **What permission is missing is not documented.** Our error: `opening stable reference to process …: operation not permitted` (frontend runs as uid 1000).
  - Likely `CAP_KILL` (signal another user's process). Possibly other checks.
- Plan: **try `KILL` first** (smallest step). If it still fails, use `privileged: true` (= "all permissions").

### A5. Why short-lived processes are not traced 🔬 (partly documented)

```
curl starts ─► sends request ─► gets reply ─► exits          (≈ 20–50 ms total)
                    ...OBI notices the new process
                    ...waits min_process_age (5 s, our config)
                    ...reads binary, attaches probes, adds PID to the filter map
                    → process is already gone
```

- The eBPF probes are attached kernel-wide, but they **drop events from PIDs not in OBI's filter map**. A PID is added only after discovery.
- `capture.policy.min_process_age: 5s` (✅ in our config) is there on purpose: skip noisy short processes (shell commands, health scripts) and avoid the cost of attaching probes to every process.
- Even with `min_process_age: 0`, attaching takes longer than curl lives (🔬).
- **Fix for the POC:** make loadgen a **long-lived process** (one Python or Go process with keep-alive connections). Then the trace starts at loadgen and shows the real end-to-end time including the network.

### A6. Internal functions of the app: can eBPF show them? 📄/🔬

**Short answer:** OBI does **not** create spans for your own functions (no custom-function spans in OBI docs). It sees **edges**: incoming and outgoing requests, DB calls, and runtime events.

| Option | What you see | eBPF? | Code? |
|---|---|---|---|
| OBI (today) | waterfall of **services and calls** across pods | yes | no |
| **OTel SDK manual spans** (hybrid) | waterfall **including internal functions** (`validate_order`, `calculate_price`) across pods | no | yes |
| **OTel auto-instrumentation agents** (Python/Node/Java via the OTel Operator annotation) | spans for frameworks and libraries (Express routes, FastAPI, psycopg, httpx), not your custom functions unless decorated | no (language agents) | no app code, but changes the pod (injected agent) |
| OBI Node.js "manual spans" | spans you create with `@opentelemetry/api` in Node, exported by OBI | yes | yes (API calls). 📄 **config v1 only**; we use v2 |
| **Continuous profiling** (e.g. Pyroscope / OTel eBPF profiler) + OBI **trace-profile correlation** (`traces_ctx_v1` pinned map, `populate_trace_context`) | **flame graphs**: which functions burned CPU, possibly per span | yes | no |
| `bpftrace` uprobes on Go functions | latency histogram of one Go function (ad-hoc) | yes | no |

- For Python and Node, your functions are **interpreted**. A uprobe sees the interpreter's C functions, not `def calculate_price`. That's why eBPF-only tools use profiling (stack sampling), not function spans.
- ⚠️ If we add the SDK to a service, OBI by default **stops instrumenting it and stops injecting headers** (`exclude_otel_instrumented_services: true`). That's an important detail for the hybrid phase (Phase 7).
- **To get "waterfall across pods including internal functions"** you need SDK spans (or agents), with OBI covering the rest. That's CLAUDE.md Phase 7.

### A7. What is a CNI (simple), and how it relates to OBI

**CNI = Container Network Interface.** When a pod starts, the kubelet asks the CNI plugin: *"give this pod a network"*. The plugin:
1. creates a virtual cable (**veth pair**) between the pod and the node,
2. gives the pod an **IP** from the node's range (ours: `10.244.1.0/24` on worker, `10.244.2.0/24` on worker2),
3. sets **routes**, so pods on other nodes can be reached.

In kind the CNI is **kindnet** (simple routes). On EKS it's usually the **AWS VPC CNI** (pods get VPC IPs). **Cilium** and **Calico** add network policies; Cilium does it with eBPF.

```
orders pod ─veth─► worker2 netns ─route─► worker netns ─veth─► payments pod
   ▲ OBI works HERE: at the socket, above the CNI          (CNI moves packets below)
```

How it relates to OBI:
- OBI hooks **sockets** (kprobes, sk_msg), which sit **above** the CNI, so it works with any CNI ✅ (kindnet in our case).
- 🔬 **Cilium** also uses eBPF (TC programs, socket-level load balancing, sometimes sockmap). Two eBPF users on the same hooks must be tested together. Socket-LB can make OBI see the **pod IP** instead of the Service IP.
- **Network policies** must allow OBI (hostNetwork) → Collector traffic.
- Later with Istio: the **istio-cni** plugin sets the traffic redirect to Envoy.
- Hubble (Cilium) gives **network flow** visibility (who talked to whom, drops); OBI gives **application** visibility. They complement each other.

---

## Part B: The plan (execute after review, step by step, with a checkpoint after each)

Order matters. Steps 1–3 make **one trace per order** possible. Step 4 maps order ↔ trace. Step 6 builds the incident tooling.

### Step 0: Safety baseline (no changes)
- `free -h`, `make bpf-progs`, `bpftool link show`, kernel log line count, pod restarts.
- Record the current OBI values (git) for rollback.

### Step 1: Node.js frontend in-process linking ❓
- 1a. `observability/values-obi.yaml`: `extraCapabilities: [SYS_ADMIN, KILL]`. Upgrade OBI, restart the stateless apps.
- Verify: the OBI log no longer says `unable to capture stable node injection target`; TraceQL `{resource.service.name="frontend" && kind=server} >> {resource.service.name="frontend" && kind=client}` count ≈ number of frontend requests.
- 1b. Only if 1a fails: `privileged: true` (all permissions), the same checks, and a bpftool diff.
- Watch for: the frontend opening an inspector port (🔬 check `ss -ltnp` in the pod), and frontend errors.
- Rollback: the previous values + `make obi` + restart apps.

### Step 2: orders: remove the asyncio gap ❓
- Option A (recommended): rewrite `orders` with **Flask + gunicorn** (sync, like payments, which works ✅). Same endpoints and behaviour; new image `shop/orders:0.2.0`.
- Option B (experiment first, 10 min): keep FastAPI and change the handlers to `async def` with async clients; record the result as evidence.
- Record "FastAPI/ASGI + threadpool" as a **stack limitation** in the deep-dive doc.
- Verify: `{resource.service.name="orders" && kind=server} >> {resource.service.name="postgres"}` > 0.

### Step 3: loadgen as a long-lived process ❓
- Replace the curl loop with a small **Python** loop (one process, `requests.Session` keep-alive), the same behaviour (robot switch, restock with admin login). New image `shop/loadgen:0.3.0`. RAM about 30 MiB.
- Verify: `loadgen` appears as a service; traces start at loadgen.
- Goal check (Steps 1–3): `{resource.service.name="loadgen"} >> {resource.service.name="postgres" && name="UPDATE orders"}` → **one trace per order** with about 14 spans across both nodes.

### Step 4: Order ↔ trace mapping (idea 1)
- `orders`: read the incoming `traceparent` header → `trace_id` (32 hex).
  - DB: `ALTER TABLE orders ADD COLUMN trace_id TEXT` (at startup, `IF NOT EXISTS`).
  - Log: one line per order: `order_created order_id=3051 status=paid trace_id=4bf9…`.
  - API: return `trace_id` in the `POST /orders` and `GET /orders` responses.
- `frontend`: show `trace_id` in the "Recent orders" table as a **link to Grafana Explore** (Tempo, trace id).
- Admin page: "find order" box → shows status, trace link.
- Verify: pick any order → click → the full trace opens. Also `psql … where trace_id = '…'` works in reverse.
- Note: this is **business code** (reading a header + saving it), not tracing code. OK under rule 7? ❓

### Step 5: OBI log enricher (idea 2, experiment) ❓
- OBI values: `correlation.log_trace_annotation.enabled: true`; add a **hostPath volume `/sys/fs/bpf`** (chart `volumes`/`volumeMounts`).
- App pods: env `PYTHONUNBUFFERED=1` for orders and payments.
- Verify: `kubectl logs deploy/payments` lines end with `trace_id=… span_id=…`; compare with the Step 4 log line.
- Risks: OBI rewrites app log output (NUL placeholder lines); pinned maps stay in bpffs → rollback must clean `/sys/fs/bpf/otel` 🔬.
- Decide afterwards: keep or remove.

### Step 6: Fault injection via ConfigMap, no restarts ❓

**Design**
- New ConfigMap `shop-faults` (Helm template, defaults = no faults), one file `faults.json`:
  ```json
  {
    "orders":    {"delay_ms_max": 0, "error_rate": 0.0, "error_code": 500},
    "payments":  {"delay_ms_max": 50, "error_rate": 0.02, "error_code": 500},
    "inventory": {"delay_ms_max": 0, "error_rate": 0.0, "error_code": 503},
    "frontend":  {"delay_ms_max": 0, "error_rate": 0.0, "error_code": 502}
  }
  ```
  Optional per-pod override (only useful with replicas > 1): `"orders": {"default": {...}, "pods": {"orders-abc": {...}}}` ❓
- Mounted as a **volume** (not `subPath`, because subPath never updates) at `/etc/shop-faults/faults.json` in each app pod.
- Each app: tiny middleware, the same logic in Python, Go and Node:
  - re-read the file when its modification time changes (check at most every 2 s),
  - for business routes (not `/health`): sleep `random(0..delay_ms_max)`, then with probability `error_rate` return `error_code`.
- `payments` moves from env vars to this file (env stays as a fallback).
- **No restart needed:** the kubelet updates ConfigMap volumes in place.
  - 🔬 Delay is roughly 30–90 s (kubelet sync period + cache).
  - Speed-up to test: the script also **annotates the pods**, which should trigger a quicker kubelet sync 🔬.
- Helm owns the defaults. `make deploy` (`--reset-values`) **resets all faults**. That's the "panic button".

**Scripts** (`scripts/`)
```
scripts/faults.sh show                                   # current faults per service
scripts/faults.sh set payments --delay 1500 --error-rate 0.25 --code 503
scripts/faults.sh clear [service|all]
scripts/incident.sh slow-payments   --for 5m             # preset: payments delay 1500 ms
scripts/incident.sh flaky-orders    --for 5m             # preset: orders 20% → 500
scripts/incident.sh inventory-down  --for 3m             # preset: inventory 100% → 503
```
- Each incident script: patches the ConfigMap (`kubectl patch` + `jq`), waits until the pods see it (reads `/etc/shop-faults/faults.json` via `kubectl exec`), **writes start/end UTC to `docs/incidents.log`**, auto-clears after `--for`, and has a `trap` so Ctrl+C also clears.
- Verify: change faults → no pod restarts (`RESTARTS` unchanged) → dashboard shows the effect within ~1–2 min → clear → recovery.

### Step 7: Incident drills + docs
- Run 3 presets; for each: find it on the dashboard → TraceQL → one full trace → the order id (Step 4).
- Update the runbook, phase notes, deep-dive limitations; commit per step.

### Later (only when you ask): internal functions
- Phase 7 hybrid: OTel SDK manual spans in `orders` (remember `exclude_otel_instrumented_services`).
- Optional: OTel Operator auto-instrumentation comparison, and continuous profiling + `traces_ctx_v1` correlation.

---

## RAM impact (estimate)

| Change | Extra RAM |
|---|---|
| Step 1 (permissions) | ~0 (maybe a few MiB in frontend for the injected agent) |
| Step 2 (Flask instead of FastAPI) | ~0 |
| Step 3 (Python loadgen) | +~25 MiB |
| Step 5 (log enricher) | OBI +? 🔬 (async writer workers) |
| Step 6 (faults) | ~0 |
| Loki for logs (NOT planned) | +150–250 MiB; skip unless you want log search in Grafana |

Today: ~3.1 GB free → all steps fit.

---

## Questions for you ❓

1. **Fault injection scope.** Which services: orders + payments only, or all four (frontend, orders, inventory, payments)? And does "by pods" mean **per service** (all pods of orders) or **per individual pod** (one orders pod of several)? Today every service has 1 replica.
2. **orders.** OK to **rewrite it with Flask + gunicorn** (Step 2 option A), or first try `async def` as an experiment?
3. **Node permissions.** Try `KILL` first and go to `privileged: true` only if needed, or straight to `privileged: true`?
4. **Order ↔ trace mapping (Step 4).** Reading `traceparent` in `orders` and storing it is a small **business** code change (no SDK). Is that OK with the "no tracing code" rule?
5. **Log enricher (Step 5).** Run the experiment (adds a bpffs mount and log rewriting), or skip?
6. **loadgen.** OK to replace curl with a long-lived Python loadgen?

## Sources

- OBI distributed traces / context propagation: https://opentelemetry.io/docs/zero-code/obi/distributed-traces/ , https://opentelemetry.io/docs/zero-code/obi/context-propagation/
- OBI trace-log correlation: https://opentelemetry.io/docs/zero-code/obi/trace-log-correlation/ and repo `devdocs/trace-log-correlation.md`
- OBI trace-profile correlation: repo `devdocs/trace-profile-correlation.md`
- OBI context propagation internals: repo `devdocs/context-propagation.md`
- OBI config v2 / security: https://opentelemetry.io/docs/zero-code/obi/configure/config-v2/ , https://opentelemetry.io/docs/zero-code/obi/security/
- W3C Trace Context L1 / L2: https://www.w3.org/TR/trace-context/ , https://www.w3.org/TR/trace-context-2/
- Our OBI v1.0.0 config dump (`obi config migrate`): keys `capture.policy.min_process_age`, `capture.runtimes.nodejs`, `correlation.log_trace_annotation`
