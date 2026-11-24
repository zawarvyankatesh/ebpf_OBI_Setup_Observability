# Observability deep dive: OBI POC on kind

Simple-English notes on **where we are, what is missing for production, and why**.
Everything marked ✅ was **seen in this POC**. Everything marked 🔬 is **not verified yet** (needs a lab test).

Related files: [runbook.md](runbook.md) (every command), [phase-notes.md](phase-notes.md) (short learnings).

---

## Contents

1. [How data and traces flow right now](#1-how-data-and-traces-flow-right-now)
2. [The Node.js issue](#2-the-nodejs-issue)
3. ["Order 3051 was slow": how do I get its graph?](#3-order-3051-was-slow-how-do-i-get-its-graph)
4. [The kernel changes packets: is that OK in production?](#4-the-kernel-changes-packets-is-that-ok-in-production)
5. [Limitations today vs production grade](#5-limitations-today-vs-production-grade)
6. [What OBI does NOT replace (other dashboards, Coroot)](#6-what-obi-does-not-replace-other-dashboards-coroot)
7. [Tech stack support, and what we could swap](#7-tech-stack-support-and-what-we-could-swap)
8. [What we did to the running application](#8-what-we-did-to-the-running-application)

---

## 1. How data and traces flow right now

### 1.1 The pipeline (both nodes)

```
 ┌───────────────────── obi-poc-worker / obi-poc-worker2 (each node) ─────────────────────┐
 │  app pods (shop)                                                                       │
 │     │ socket read/write, Go functions                                                  │
 │ ════▼═══════════ shared Linux kernel (WSL2 6.18.33) ══════════════════════════════════ │
 │   kprobes / uprobes ──► copy first bytes + timestamps ──► eBPF maps ──► ring buffer    │
 │   sock_ops + sk_msg ──► add trace context to outgoing requests (propagation)           │
 │ ════│══════════════════════════════════════════════════════════════════════════════════ │
 │     ▼                                                                                  │
 │  OBI pod (DaemonSet, user space): parse protocol → span + counters → add k8s labels    │
 └─────│──────────────────────────────────────────────────────────────────────────────────┘
       │ OTLP/gRPC   traces every 5 s, metrics every 15 s
       ▼
  OTel Collector (memory_limiter → batch)
       ├── traces  ── OTLP/gRPC ──► Tempo        (2 h, emptyDir)
       └── metrics ── OTLP/HTTP ──► Prometheus   (native OTLP receiver, 6 h, emptyDir)
                                         ▲
                     Grafana ────────────┘ (+ Tempo datasource, service map, dashboard)
```

### 1.2 How spans get joined into one trace

There are **3 different mechanisms**. Each hop in our app uses one of them, or fails.

| Mechanism | Where | How | Needs |
|---|---|---|---|
| **A. In-process** | inside one app | OBI links "request came in" to "calls going out" for the same request. Go: by goroutine (uprobes). Python: by thread. Node: needs injection (see §2). | Works per runtime |
| **B. Black-box (same node)** | two apps on the **same node** | One OBI sees both ends of the same TCP connection and matches them in memory. Nothing is written to packets. | Both ends seen by the same OBI pod |
| **C. Network propagation** | across nodes | OBI **adds trace context to the outgoing request**: a W3C `traceparent` HTTP header (`headers`) and/or a TCP option (`tcp`). The receiving side's OBI reads it. | `context_propagation`, NET_ADMIN, and on our kernel **SYS_ADMIN** (§4) |

### 1.3 Our app, hop by hop (✅ measured with TraceQL)

```
loadgen ──► frontend ══► orders ──► inventory ──► redis
 (w2)        (w1)        (w2)  └──► payments (w1)
                               └──► postgres (w2)
```

| Hop | Nodes | Joined? | Why |
|---|---|---|---|
| loadgen → frontend | w2 → w1 | ❌ | every `curl` is a new process living < 1 s; OBI only instruments processes older than `min_process_age` (5 s) |
| frontend (server → its own client call) | w1 | ❌ mostly | Node.js in-process tracking needs injection, which failed (§2) |
| frontend → orders | w1 → w2 | ⚠️ joined right after enabling propagation (10/10), later 0/43 | depends on the frontend in-process link; 🔬 why it changed is not fully understood |
| orders (server → its own client calls) | w2 | ❌ | FastAPI receives on the asyncio loop, runs our `def` handler on **another thread** → link lost |
| orders → inventory | w2 → w1 | ✅ 43/43 | propagation (mechanism C) |
| orders → payments | w2 → w1 | ✅ 42/42 | propagation (mechanism C) |
| inventory → redis | w1 → w2 | ✅ | Go in-process (A) + RESP protocol decoding |
| orders → postgres | w2 → w2 | ✅ client + server spans | Postgres wire protocol decoding |

**Result:** one order today = **about 5 small traces**, not 1 (see the order 3051 example in §3).

---

## 2. The Node.js issue

### 2.1 Why Node.js is hard for eBPF

- Python (gunicorn) and Java often use **one thread per request**, so "same thread" ≈ "same request". OBI can link incoming and outgoing calls by thread.
- Go has **goroutines**, and OBI follows them with uprobes on Go runtime functions.
- **Node.js runs everything on ONE thread** (the event loop). 100 requests are handled in small slices on the same thread. From the kernel's view, a `write()` to `orders` could belong to any of them, so the thread ID tells OBI nothing.

### 2.2 What OBI does about it

OBI's answer for Node.js is to **inject a small helper inside the Node process**:

1. Send the process **SIGUSR1**. Node reacts to SIGUSR1 by **opening its built-in inspector (debugger)**.
2. Use the inspector to load a tiny script that tags async work. Node has `async_hooks`/`AsyncLocalStorage` for this.
3. Now OBI can tell which outgoing call belongs to which incoming request.

This is the "Node SIGUSR1 caveat" in CLAUDE.md. It also gives Node **runtime metrics**.

### 2.3 What happened in our POC (✅ seen)

OBI log on `obi-poc-worker`:

```
unable to capture stable node injection target, Node.js trace correlation and runtime metrics will not work
error="capturing stable identity for process 14256: opening stable reference to process 14256: operation not permitted"
```

- The `frontend` process runs as **uid 1000** (non-root, by our design).
- OBI runs as root but **without most capabilities**: we gave only BPF, PERFMON, SYS_PTRACE, CHECKPOINT_RESTORE, DAC_READ_SEARCH, NET_RAW, then NET_ADMIN and SYS_ADMIN.
- The kernel refused a step of the injection with `operation not permitted`.
- 🔬 **Likely cause:** sending a signal to a process owned by **another user** needs **CAP_KILL**, which OBI does not have. Not proven; it needs a test (add `KILL` to `extraCapabilities`).

### 2.4 Effects and options

| Effect | Impact |
|---|---|
| frontend's server span is not linked to its outgoing calls | frontend → orders / inventory often not in one trace |
| no Node.js runtime metrics | e.g. no event-loop lag |
| HTTP RED metrics for frontend | **still fine** (they come from kernel probes) |

| Option | Trade-off |
|---|---|
| Add `CAP_KILL` 🔬 | OBI may signal any process; it opens a **debugger port inside your app** (security review needed) |
| Run OBI `privileged: true` | simplest, biggest permission |
| Swap frontend to **Go** for the POC | best OBI support (uprobes); mention "Node.js needs injection" as a limitation |
| OTel SDK in the Node app | code change, but the most reliable for Node |

Watch out in production: if an app **uses SIGUSR1 itself** (some apps use it for log reopen or reload), injection can clash with it.

---

## 3. "Order 3051 was slow": how do I get its graph?

### 3.1 Metrics cannot show one order (by design)

A graph in Grafana is a **metric**: one number over time for a **group** of requests (per service, route, status code).
If we added `order_id` as a label, every order would create **new time series**. That's "high cardinality", which breaks Prometheus memory and cost.
So: **metrics answer "is something wrong, where, since when?"; traces answer "what happened to THIS request?"**

### 3.2 The workflow we used (✅ worked)

1. **Find the time** in the system that knows the order id (the database):
   ```bash
   kubectl -n shop exec deploy/postgres -- psql -U shop -d shop \
     -c "select id, status, created_at from orders where id = 3051"
   # 3051 | paid | 2026-11-24 05:56:13.612654+00
   ```
2. **Look at the dashboard around that time**: was payments or orders slow then? (rate, p95, errors)
3. **Search Tempo in a ±2 s window** (Grafana → Explore → Tempo, or TraceQL):
   ```
   {resource.service.name="orders"}            time range 05:56:12 → 05:56:15
   ```
4. **Match by timestamp**: the `INSERT orders` span started at `05:56:13.612`, the DB says `13.612654`.
5. Read the pieces (5 traces, because of the gaps in §1.3):
   ```
   13.606 frontend SERVER POST /api/orders  63 ms
   13.608 orders   SERVER POST /orders      60 ms   (joined with frontend)
   13.610 orders → inventory POST /reserve   1 ms   → redis decrby
   13.612 orders → postgres  INSERT          0.7 ms
   13.620 orders → payments  POST /pay      43 ms   ← most of the time
   13.665 orders → postgres  UPDATE          0.3 ms
   ```

**Weak point:** matching by time works at ~1 order/s. At 100+ orders/s many orders share the same millisecond, so you can't tell which trace is order 3051.

### 3.3 How production teams make it exact

| Way | How | Cost |
|---|---|---|
| **Span attribute via OTel SDK** (hybrid; Phase 7) | in `orders`: `span.set_attribute("order.id", 3051)` → TraceQL `{span.order.id = 3051}` | small code change in one service; also fixes the asyncio gap |
| **Trace ID in logs** | app logs `order_id=3051 trace_id=…` → search logs (Loki) → click to trace | needs a log pipeline (we have none). 🔬 OBI has a "log enricher" option (`logenricher=false` in our logs): check whether it can add trace ids to app logs |
| **Trace ID in the DB row / API response** | store `trace_id` with the order, or return it in a response header | app change; great for support teams |
| **Exemplars** | a dot on a latency graph links to one example trace | Prometheus needs `exemplar-storage`; 🔬 not verified that OBI sends exemplars |

A "graph" for a single order is really its **trace waterfall** (Tempo view). For the *group* ("orders for cherries are slow"), you'd add a **low-cardinality** attribute (item type, customer tier) and build span metrics on it, never on the order id.

---

## 4. The kernel changes packets: is that OK in production?

### 4.1 What exactly is changed (✅ seen with bpftool)

With `context_propagation: all`, OBI loaded and **attached**:

| Program type | Attached to | What it does |
|---|---|---|
| `sock_ops` (`obi_sockmap_tracker`) | the cgroup tree (2 cgroup links) | sees TCP connections of instrumented apps being created, puts them into a **sockhash** map (we saw 13 and 8 sockets) |
| `sk_msg` (`obi_packet_extender_*`) | the sockhash | runs **on each message the app sends, before TCP**. For HTTP requests without `traceparent`, it **makes the message longer and writes a `traceparent:` header** into it (`write_msg_tp`, `create_tp`; HTTP/2 variants exist too) |
| TCP option (`tcp` mode) | TCP header | trace id in a TCP option; only another OBI can read it; the app never sees it |
| FIONREAD fix-up (`obi_fionread_fixup_exit`) | syscall exit | corrects a number the kernel returns to the app (see 4.2). Uses `bpf_probe_write_user` = **writes into app memory** |

No TC/XDP programs were attached (0 on both nodes).

### 4.2 Why SYS_ADMIN was needed on our kernel (✅ seen)

OBI log: *"kernel misreports ioctl(FIONREAD) for sockets in a sockhash (kernel commit 929e30f93125, present in 6.6.128+, 6.12.75+, 6.18.14+ and 6.19+)"*.

- Apps use `ioctl(FIONREAD)` to ask "how many bytes can I read?". On these kernels the answer is wrong for sockets inside OBI's sockhash.
- OBI fixes it with a program that writes the right number back into the app's memory. The verifier allows that helper only with **CAP_SYS_ADMIN**.
- Without SYS_ADMIN, OBI **refuses** propagation ("would risk making applications … stall or truncate transfers"). That's a good safety decision.

**So the permission you need depends on the kernel version.** Older kernels without that commit may not need SYS_ADMIN (🔬 not tested here).

### 4.3 Is it acceptable in production? It depends; here's the checklist

Many companies **do** run privileged eBPF agents in production (CNI plugins like Cilium, security tools, APM agents). The question is risk vs value.

| Concern | Detail | Mitigation |
|---|---|---|
| **Privilege** | NET_ADMIN + **SYS_ADMIN** (≈ root on the node) | dedicated node pools, Pod Security exemption only for OBI's namespace, signed and pinned image, RBAC review |
| **Payload change** | OBI rewrites outgoing HTTP bytes | canary rollout (one node pool first), watch error rates, quick rollback (`helm uninstall` → ✅ programs removed) |
| **Writes into app memory** | FIONREAD fix-up and Go library-level propagation | needs a security sign-off; blocked by kernel **lockdown=integrity** |
| **Kernel dependency** | behaviour differs by kernel version (FIONREAD) | test on the **exact** node OS/kernel you use (EKS AL2023, Bottlerocket, …) |
| **Lockdown** | Secure Boot / hardened OS → `lockdown=integrity` blocks `bpf_probe_write_user` | then propagation is off on newer kernels. 🔬 Bottlerocket is often configured with integrity lockdown: check `cat /sys/kernel/security/lockdown` |
| **Managed / serverless nodes** | EKS **Fargate**, GKE Autopilot | no DaemonSets / no privileged pods → **no OBI** there (Autopilot: 🔬 check allow-lists) |
| **Version churn** | OBI 1.0 is new; chart defaults differ from docs | pin versions, render and review every upgrade (we caught `privileged: true` and propagation defaults in the chart) |

**Lower-risk choices:**
- **Propagation off, metrics + per-service spans only.** That's our Phase 5 setup: least privilege, still very useful.
- **Propagation only where needed**, with header injection only (`headers`), not `tcp`.
- **SDK propagation in critical services**: no kernel changes, but needs code (hybrid model).

### 4.4 Where it CANNOT work

| Case | Why |
|---|---|
| **App does TLS itself** (HTTPS from the app) | OBI can read plaintext via uprobes on TLS libraries, but **cannot insert a header into encrypted bytes**. Only TCP-option mode (OBI↔OBI) is left |
| **L7 proxies / load balancers in between** | they end the TCP connection, so the **TCP option is lost**. A plaintext **header survives** if the proxy forwards headers |
| Short-lived processes | instrumented only after `min_process_age` (our `curl` loadgen) |
| Connections opened before OBI started | not tracked → restart apps after OBI |
| Fargate / serverless | no node access |
| Windows nodes | eBPF here is Linux-only |

### 4.5 Your future setup: no app TLS, Envoy mesh (Istio)

Your plan: the apps speak **plain HTTP**, and **Envoy** does mTLS between pods. That fits OBI well, with some rules:

```
app ──plain HTTP──► local Envoy ══mTLS══► remote Envoy ──plain HTTP──► app
  ▲ OBI injects traceparent here (before Envoy encrypts)
```

- ✅ **Use `context_propagation: headers`.** The header is inserted **before** Envoy encrypts, so it travels inside mTLS and arrives at the other app.
- ❌ **`tcp` mode won't help.** Envoy terminates TCP, so the option dies at the sidecar.
- Envoy forwards unknown headers by default. If Istio tracing is on, use the **W3C/OpenTelemetry** tracer, not B3, so Envoy continues the same `traceparent`.
- **Exclude `istio-proxy`** from OBI discovery (Envoy's own spans come from Istio).
- 🔬 To test in Phase 11: what OBI reports as the peer when iptables redirects to Envoy, ambient mode (ztunnel L4) pass-through, and HTTP/2 between app and sidecar.
- Note that this **solves a classic Istio problem**. Istio only creates spans per hop; **the app must forward trace headers itself**, or traces break inside each service. OBI's header injection plus in-process tracking can do that forwarding without code, **if** in-process linking works for that runtime (§1.2 A). With Node or Python asyncio it might not.

---

## 5. Limitations today vs production grade

### 5.1 Coming from OBI / eBPF itself

| Limitation | Why | Production answer |
|---|---|---|
| No business data (order id, user, amount) | OBI sees protocol bytes, not meaning; bodies not exported | SDK attributes on key services (hybrid) |
| No internal function spans, no exceptions or stack traces | only network / runtime boundaries are visible | SDK or profiling (e.g. Pyroscope) |
| Trace gaps in Node.js and Python asyncio | single-thread / thread-hop context tracking (§1.3, §2) | injection permissions, SDK, or a different framework |
| Propagation needs high privilege on new kernels | FIONREAD fix-up → SYS_ADMIN (§4.2) | accept on dedicated nodes, or no propagation |
| Encrypted app traffic and L7 proxies | §4.4 | header mode, mesh-friendly design |
| Pre-existing connections not seen | no socket scan without setns (SYS_ADMIN) | restart apps after OBI (fixed with SYS_ADMIN for scanning) |
| Short-lived processes not traced | `min_process_age` | fine for clients like curl; long-lived load tools |
| Memory per node 250–420 MiB | per-runtime probes and maps | sizing; measure (Phase 8) |
| Kernel / OS dependence | BTF, lockdown, kernel commits | test per node image |

### 5.2 Coming from our POC setup (fixable, not OBI's fault)

| Area | Today | Production grade |
|---|---|---|
| Storage | Prometheus 6 h, Tempo 2 h, **emptyDir** (lost on restart: we saw Tempo lose traces) | object storage (S3) for Tempo, Thanos/Mimir or AMP for metrics, PVCs |
| High availability | 1 replica each, one Collector | 2+ replicas, Collector as DaemonSet/gateway with persistent queues |
| Sampling | 100% of traces | head or **tail sampling** in the Collector (keep errors and slow ones) |
| Alerting | Alertmanager off, no rules | SLO-based alerts on RED (error budget burn) |
| Logs | none (no Loki) | log pipeline with trace_id correlation |
| Infra metrics | no node-exporter, no kube-state-metrics | needed for USE and k8s state (see §6) |
| Security | Grafana admin user, no TLS, OBI with SYS_ADMIN (lab) | SSO, TLS, least-privilege review |
| Resource limits | tuned by trial (Grafana, Tempo were killed by liveness probes under low CPU limits) | load-test and right-size |
| Config management | Helm `--set` drift (we hit it in the incident demo) | GitOps (Argo CD / Flux), `--reset-values` |
| Cluster name | set by hand (`OTEL_EBPF_KUBE_CLUSTER_NAME`) | set per cluster via values |
| Overhead | not measured yet | Phase 8: CPU/RAM of OBI, app p99 with vs without |

---

## 6. What OBI does NOT replace (other dashboards, Coroot)

### 6.1 The kube-prometheus-stack dashboards we switched off

kube-prometheus-stack normally ships many dashboards: "Kubernetes / Compute Resources / …", "Node Exporter / Nodes", "Kubernetes / Networking", API server, kubelet, etc.
They use **other data sources**, not OBI:

| Dashboard family | Data source | OBI covers it? |
|---|---|---|
| Node CPU / memory / disk / filesystem (USE) | **node-exporter** | ❌ (we turned node-exporter off) |
| Pods / deployments / restarts / OOMKilled / replicas / PVC | **kube-state-metrics** + cAdvisor | ❌ (KSM off; we kept only cAdvisor CPU/RAM) |
| Container CPU / memory | **cAdvisor** (kubelet) | ❌, but ✅ we still scrape it |
| Control plane (API server, etcd, scheduler) | component metrics | ❌ |
| **App RED, service map, DB/Redis calls, DNS** | **OBI** | ✅ this is OBI's job |
| Network bytes / TCP RTT / retransmits per flow | OBI **network** feature (off in our setup) | ✅ possible (not enabled) |

**OBI = app-level "what is my service doing", not infrastructure health.** In production you run OBI **next to** node-exporter, kube-state-metrics and logs, not instead of them.

### 6.2 OBI vs a full eBPF APM such as Coroot (for the later comparison phase)

| | OBI (our stack) | Coroot (full product) |
|---|---|---|
| What it is | a **building block**: produces OTel traces + metrics | a complete platform: agent + storage + UI + analysis |
| Storage / UI | you choose (Prometheus, Tempo, Grafana) | built in (with ClickHouse / Prometheus) |
| Logs, profiling, node metrics | ❌ (other tools) | ✅ included in its agent |
| Root-cause hints, SLO inspections | ❌ (you build dashboards and alerts) | ✅ built-in "inspections" |
| Vendor neutrality | ✅ OpenTelemetry standard | its own data model (exports some) |
| Effort | more assembly work | install and go |

🔬 Exact Coroot features need checking in Phase 12.

---

## 7. Tech stack support, and what we could swap

| Service | Stack | OBI status in this POC | Swap option for the POC | Limitation to document |
|---|---|---|---|---|
| inventory | **Go** net/http + go-redis | ✅ best: uprobes, in-process, Redis spans | keep | binary must keep symbols (not stripped) |
| payments | Python **Flask + gunicorn** (sync) | ✅ server + in-process (`in queue` / `processing`) | keep | none seen |
| orders | Python **FastAPI + uvicorn** (asyncio → threadpool) | ⚠️ server span not linked to its own calls | **Flask + gunicorn** (same as payments), or a Go service | "Python asyncio / ASGI frameworks lose in-process context" |
| frontend | **Node.js + Express** | ⚠️ in-process link missing (injection EPERM) | **Go** net/http (or test CAP_KILL first) | "Node.js needs in-process injection via SIGUSR1/inspector + extra permissions" |
| loadgen | curl in a shell loop | ❌ never traced (processes < 1 s) | long-running Go/Python client if we want root spans | "short-lived processes not instrumented" |
| postgres, redis | official images | ✅ protocol decoding, client + server spans | keep | query text / parameters not captured |

**Suggested next experiment:**
1. Re-write `orders` with Flask + gunicorn. It's tiny, and the same pattern already works in payments.
2. Then either test `CAP_KILL` for Node, or re-write `frontend` in Go.

Expected result: one order = **one trace**, which also makes the order-3051 search much easier.

---

## 8. What we did to the running application

### 8.1 Application code: zero tracing changes

- **No** OpenTelemetry library, no tracing code, no env vars like `OTEL_*`, no sidecar, no annotation in the `shop` Helm chart.
- Choices made at build time that **help** OBI (not instrumentation):
  - Go `inventory` built **with symbols** (no `-ldflags="-s -w"`), so uprobes can find `net/http` and go-redis functions.
  - Non-root numeric users (`runAsNonRoot` works). This later explained the Node.js permission issue.
- `nodeSelector` placement on purpose: frontend/inventory/payments on worker, orders/postgres/redis/loadgen on worker2, so we could study **cross-node** traces.

### 8.2 Things done *around* the running app

| Step | Why |
|---|---|
| Installed the backend: Prometheus (OTLP receiver), Tempo, Grafana, OTel Collector | somewhere to send, store and see data |
| Installed OBI as a **DaemonSet** in `observability` with read-only RBAC (pods, services, nodes, replicasets) | one agent per node; k8s names on spans |
| Overrode the chart defaults: `privileged: false`, 6 capabilities, rules = **only namespace `shop`**, OTLP to the Collector | safety and scope |
| Set `OTEL_EBPF_KUBE_CLUSTER_NAME=obi-poc` | kind doesn't expose a cluster name |
| **Restarted app pods after every OBI (re)install** | OBI must see connections being opened |
| Phase 6: `application_service_graph` feature | service map metrics |
| Phase 6: `contextPropagation.enabled: true`, `context_propagation: all`, then **SYS_ADMIN** (lab only) | cross-node traces on kernel 6.18 |
| Raised limits: OBI 768Mi, Grafana 1 CPU/512Mi, Tempo 1 CPU/768Mi | measured needs; liveness kills under low CPU limits |
| Dashboard as code (`observability/dashboards/shop-red.json` → ConfigMap → Grafana sidecar) | repeatable |

### 8.3 What changed in the kernel (✅ bpftool)

| State | eBPF programs | Notes |
|---|---|---|
| Before OBI | 133 | 116 `cgroup_device` from runc (every container already uses eBPF) |
| OBI observe-only | +~360 `obi_*` | kprobes/uprobes (shown as `kprobe`), 6 `socket_filter`, `tracing`, `tracepoint`; ~318k instructions verified; ~9 MiB locked memory |
| + propagation (SYS_ADMIN) | + 24 `sk_msg`, 2 `sock_ops`, FIONREAD fix-up | 2 `cgroup_sock_ops` links, sockhash maps filled; **no TC/XDP** |
| After `helm uninstall` | `obi_*` = 0 | nothing pinned in bpffs, so the kernel cleans up when OBI exits |

Kernel log: no bpf/verifier/oops lines at any step.

### 8.4 Side effects we hit (good to remember)

- Restarting Redis or Postgres **wipes the data** (no persistence). inventory seeds stock only at startup → 409/500 until **admin Restock**.
- `helm upgrade` without values flags **kept old `--set` values** → `make deploy` now uses `--reset-values`.
- Brand-new metric series make `rate()` look wrong for about a minute (one sample per 15 s).
- Tempo restarts lose traces (emptyDir).

---

## Quick answers

- **Is the kernel changing packets?** With propagation on, yes: OBI adds a `traceparent` header and/or a TCP option to outgoing app messages. With propagation off (Phase 5 mode), it only **reads**.
- **Is it OK in production?** It can be, but treat it like a CNI or security agent: privileged, kernel-version-specific, canary rollout, security sign-off. Without propagation, it's much easier to approve.
- **For your Envoy mesh:** use `headers` mode, plain HTTP between app and sidecar, W3C tracer in Istio, exclude `istio-proxy`.
- **"Graph for one order":** not a metric. Find the time (DB/logs), then the trace. For exact lookups, add `order.id` via SDK (hybrid).
