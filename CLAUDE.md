# CLAUDE.md: OBI + eBPF Observability POC on kind

> This file carries over the full context from an earlier planning conversation.
> Read it fully before doing anything. Then follow "How to work with me" strictly.

---

## 1. About me (the user)

- I'm an **SRE / DevOps engineer**. Strong on **AWS** and **Kubernetes** (EKS, multi-account, networking). I like **AWS CDK** for infra.
- I know **Prometheus, Grafana, TSDB concepts, Helm**.
- I'm **new to eBPF and OBI**. This POC is mainly for **learning**, so understanding matters more than speed.
- Timezone: Asia/Kolkata. Language: **simple English**, please.
- My GitHub: `zawarvyankatesh`. Learning notes repo: https://github.com/zawarvyankatesh/share (see `ebpf-obi-guide/README.md`, my eBPF + OBI guide).

---

## 2. How to work with me (IMPORTANT)

1. **Step by step.** One small step at a time. Before each step, explain in 2–5 simple sentences **what** we're doing and **why**.
2. **Show the commands**, run them (or ask me to run them if they need sudo / my machine), then show **how to verify** the step worked.
3. After each **phase**, stop at a ✅ **checkpoint**: summarise what we learned, and wait for me to say "next".
4. When something is eBPF/OBI-specific, connect it back to the concepts (hooks, kprobes/uprobes, maps, ring buffer, verifier, BTF, context propagation).
5. **Laptop-friendly**: always set resource requests/limits; keep retention short; avoid heavy components.
6. **Pin versions** in Helm/Dockerfiles. Before choosing a version or chart, **check the current official docs** (OBI changes fast). Don't rely on memory for chart names, values keys or env var names; verify them.
7. Don't add tracing code to the apps unless the phase says so (the whole point is zero-code instrumentation).
8. Commit to git at the end of each phase with a clear message.

---

## 3. Goal of this POC

Build a **microservices app**, package it with **Docker** and **Helm**, run it on a **local kind cluster**, and get **traces + metrics with ZERO code changes** using **OBI (OpenTelemetry eBPF Instrumentation)**. Visualise everything in **Grafana**. Everything runs **on my laptop**.

Later (not now): experiments, Istio, comparison with Coroot, our own eBPF exporter, move to AWS EKS with CDK.

---

## 4. checks: check with commands before Phase 0

- [ ] Laptop OS: Linux (which distro + kernel?), macOS (Intel / Apple Silicon), or Windows + WSL2?
- [ ] How much RAM / CPU can Docker use? (Target: 6–8 GB RAM, 4 CPUs.)
- [ ] Container runtime: Docker Desktop, OrbStack, Colima, or native Docker on Linux?

Why it matters: kind nodes are containers that **share the host's kernel**, so OBI's eBPF programs load into my laptop's kernel (or the Docker Desktop / OrbStack / Colima Linux VM on Mac/Windows). That kernel must support BTF.

---

## 5. Key knowledge we already established (use it, don't re-research basics)

### eBPF (summary)
- Small, safe programs run **inside the Linux kernel**, attached to **hooks**: tracepoints, kprobes (kernel functions), uprobes (functions in apps/libraries, e.g. `SSL_write`), TC/XDP (network), perf events (CPU counters).
- Flow: C → bytecode → `bpf()` syscall → **verifier** (safety) → **JIT** → attach → events written to **maps / ring buffer** → user-space agent reads and exports.
- **BTF + CO-RE**: one binary works across kernels. Needs `/sys/kernel/btf/vmlinux`.
- Can't crash the kernel (verifier). Failure mode = **missing data, silently**.

### OBI facts (as of Nov 2026)
- OBI = an **application built on eBPF** (not an extension of eBPF). Started as Grafana **Beyla**, donated to OpenTelemetry in 2025. Beyla is now Grafana's distribution of OBI (imports OBI as a library).
- **OBI v1.0.0 released 30 Oct 2026.** Config **v2** is the stable config; Config v1 is frozen. Runtime metrics (Go/Java/.NET/Node/Python) are **experimental**. ⚠️ The README in my `share` repo still says "pre-1.0"; fix it when convenient.
- Runs as a **DaemonSet** with `hostPID: true`, privileges/capabilities, mounts for `/sys/fs/cgroup` and `/sys/kernel/tracing`.
- Discovery: picks processes by open port / executable / language / k8s labels. **K8s metadata** decoration via `OTEL_EBPF_KUBE_METADATA_ENABLE=true` (needs a ServiceAccount + RBAC). Gives `k8s.namespace.name`, `k8s.deployment.name`, `k8s.pod.name`, etc.
- Output: **OTLP traces** + **RED metrics** (OTLP or Prometheus endpoint), network metrics (bytes, TCP RTT, retransmits).
- How it builds a span: kprobes on socket accept/read/write → copies first bytes → detects protocol (HTTP, gRPC, SQL, Redis...) → start/end timestamps in a map → event via ring buffer → user space builds span + metrics → adds k8s labels → exports.
- HTTPS: uprobes on TLS libraries (OpenSSL etc.) see plaintext before encryption.
- **Distributed tracing** uses W3C `traceparent`:
  - Reads incoming `traceparent`; generates one if missing; respects one the app already set.
  - **Outgoing network-level propagation is DISABLED by default.** Enable with `OTEL_EBPF_BPF_CONTEXT_PROPAGATION=all` (verify current name in docs); needs `CAP_NET_ADMIN` and the cgroup mount.
  - Go: library-level propagation (writes into process memory; blocked if kernel **lockdown=integrity**, e.g. Secure Boot. Check `cat /sys/kernel/security/lockdown`).
  - HTTPS / packet-level propagation works only OBI↔OBI and **breaks through L7 proxies** (they terminate TCP). Header-level propagation on plaintext HTTP survives proxies.
  - Per-runtime limits: Go ≤6 nested goroutine levels; Node (SIGUSR1 caveat); Python asyncio; Ruby needs Puma; reactive Java can break correlation; non-Go persistent connections created **before** OBI starts may not be recognised → **deploy OBI before the apps, or restart apps after**.
- Can't see: internal function spans, exceptions with stack traces, business attributes → hybrid model (OBI everywhere + SDK on critical services).
- Istio (future phase): sidecar mode should work if app↔Envoy is plaintext and Istio uses the **OpenTelemetry/W3C** tracer (not B3); exclude `istio-proxy` from OBI discovery. Ambient (ztunnel L4) should pass headers through. **Unverified, test in lab.**

### Alternatives (for later comparison)
Beyla (same engine), Odigos (control plane), **Coroot** (full APM platform), Pixie (ad-hoc debugging), Cilium Hubble (network), Inspektor Gadget (on-demand). Build-your-own: Cloudflare `ebpf_exporter`, or Go + `cilium/ebpf`.

### Hardware / performance (later phase)
USE method (Utilization, Saturation, Errors). eBPF tools: `runqlat`, `offcputime`, `biolatency`, `tcpdrop`, `hardirqs`, `llcstat`; hardware error tracepoints `mce:mce_record`, `ras:mc_event`, `ras:aer_event`. Docker Desktop VMs hide real hardware.

---

## 6. Target architecture (Phase 1–6)

```
Laptop
└── kind cluster "obi-poc"  (1 control-plane + 2 workers)
    ├── ns: shop            ← our app (Helm umbrella chart), NO tracing code
    │   ├── frontend   (Node.js / Express)   :3000   calls orders + inventory
    │   ├── orders     (Python / FastAPI)    :8000   calls inventory + payments, uses Postgres
    │   ├── inventory  (Go / net/http)       :8080   uses Redis
    │   ├── payments   (Python / Flask)      :5000   random latency + errors (for demos)
    │   ├── postgres, redis   (Bitnami or official images, small)
    │   └── loadgen    (k6 or a small script) constant traffic
    └── ns: observability
        ├── OBI DaemonSet           → OTLP to collector
        ├── OpenTelemetry Collector → traces → Tempo, metrics → Prometheus
        ├── Prometheus  (kube-prometheus-stack, short retention, small limits)
        ├── Tempo       (single binary / monolithic, local storage)
        └── Grafana     (datasources: Prometheus + Tempo; traces↔metrics links)
```

Why these languages: to show OBI working across runtimes (Go uprobes vs generic kernel probes; Node/Python context tracking). Java is optional later (heavier on RAM).

Request flow: `loadgen → frontend → orders → (inventory, payments, postgres)`, `frontend → inventory → redis`.

---

## 7. Repo layout (create this)

```
obi-kind-poc/
├── CLAUDE.md
├── README.md                 # what we built + how to run (keep updated per phase)
├── Makefile                  # make cluster / build / load / deploy / obs / clean
├── kind/kind-config.yaml
├── apps/
│   ├── frontend/  (Dockerfile, src)
│   ├── orders/
│   ├── inventory/
│   ├── payments/
│   └── loadgen/
├── helm/
│   └── shop/                 # umbrella chart: Chart.yaml, values.yaml, templates/ (one per service)
├── observability/
│   ├── values-kube-prometheus-stack.yaml
│   ├── values-tempo.yaml
│   ├── values-otel-collector.yaml
│   ├── values-obi.yaml       # (or raw manifests if no official chart; verify in docs)
│   └── dashboards/           # Grafana JSON (RED per service, service map)
└── docs/
    └── phase-notes.md        # what I learned per phase (short, simple English)
```

---

## 8. Phases (step by step, with checkpoints)

### Phase 0: Prerequisites & kernel check
- Install/verify: docker, kind, kubectl, helm, (optional) k9s, jq.
- Kernel checks (on the Linux host or inside the Docker VM via a privileged container):
  `uname -r` (≥ 5.8 recommended) · `ls /sys/kernel/btf/vmlinux` · `cat /sys/kernel/security/lockdown`
- Optional: run one `bpftrace` one-liner to prove eBPF works on this machine.
- ✅ Checkpoint: explain what we found and whether OBI can run here.

### Phase 1: kind cluster
- `kind/kind-config.yaml`: 1 control-plane + 2 workers, port mappings for Grafana (e.g. host 3000 → NodePort), mount nothing special.
- Create cluster, verify nodes, explain "kind nodes share the host kernel".
- ✅ Checkpoint.

### Phase 2: Build the microservices (no observability code!)
- Write each service minimally (small, readable). Add `/health`, a couple of real endpoints, simple DB/Redis calls, and in `payments` a configurable random delay + error rate (env vars).
- Multi-stage Dockerfiles, small images, non-root.
- `docker build` → `kind load docker-image ... --name obi-poc`.
- ✅ Checkpoint: run locally with docker or in cluster, curl it.

### Phase 3: Helm umbrella chart for the app
- `helm/shop`: Deployments, Services, ConfigMaps, resources, probes; Postgres + Redis (dependency chart or simple manifests).
- `helm upgrade --install shop ./helm/shop -n shop --create-namespace`.
- Loadgen running → steady traffic.
- ✅ Checkpoint: app works end to end with no telemetry; show that we are "blind" right now.

### Phase 4: Observability backend
- kube-prometheus-stack (Prometheus + Grafana; disable alertmanager/heavy exporters if needed; retention ~6h).
- Tempo (monolithic, small).
- OpenTelemetry Collector (OTLP receiver → Tempo exporter; metrics → Prometheus via remote-write or prometheus exporter; explain the choice).
- Grafana datasources: Prometheus + Tempo, with trace-to-metrics / service graph links.
- ✅ Checkpoint: Grafana opens; datasources green; still no app data.

### Phase 5: Deploy OBI (the main event)
- Check the **current OBI docs** for the Kubernetes/Helm install method and Config v2 keys.
- DaemonSet in `observability` ns, `hostPID`, required capabilities, `/sys/fs/cgroup` + `/sys/kernel/tracing` mounts, ServiceAccount + RBAC for k8s metadata.
- Discovery: instrument only namespace `shop` (exclude system namespaces, collector, OBI itself).
- Export OTLP to the collector; also enable RED metrics.
- **Restart app pods after OBI is up** (persistent-connection caveat).
- Show: `kubectl logs` of OBI, `bpftool prog list` on a node (via privileged debug pod) to SEE the loaded eBPF programs.
- ✅ Checkpoint: RED metrics in Prometheus, spans in Tempo, **with zero code changes**.

### Phase 6: Dashboards & distributed traces
- Grafana dashboard: per-service rate, error %, p50/p95/p99 (from OBI metrics), service map/graph.
- Turn on context propagation (`OTEL_EBPF_BPF_CONTEXT_PROPAGATION=all` or current equivalent) and compare traces **before vs after** (separate traces vs one joined trace).
- Use `payments` delay/error env vars to create an incident and find it via metrics → trace.
- ✅ Checkpoint.

### Later phases (only when I ask)
7. Hybrid: add OTel SDK to `orders` only; compare SDK spans vs OBI spans.
8. Measure OBI overhead (CPU/mem of OBI, app p99 with vs without).
9. Build our own eBPF exporter (DNS latency per pod, or node USE metrics via `ebpf_exporter` / Go + `cilium/ebpf`).
10. "App + Hardware" dashboard (runqlat, biolatency, tcp drops next to OBI p99) + fault injection.
11. Istio experiments (sidecar W3C vs B3, ambient).
12. Install Coroot side-by-side for comparison.
13. Move to AWS EKS using **CDK** (TypeScript or Python), same Helm charts.

---

## 9. Laptop resource guardrails

- Every container gets requests/limits. Prometheus retention ≤ 6h, scrape interval 30s.
- Tempo local storage, retention ~2h.
- Disable components we don't need (Alertmanager, node-exporter if heavy, kube-state-metrics optional).
- Provide `make clean` → `kind delete cluster --name obi-poc`.

---

## 10. Useful references

- My guide: https://github.com/zawarvyankatesh/share/tree/main/ebpf-obi-guide
- OBI docs: https://opentelemetry.io/docs/zero-code/obi/
- OBI on Kubernetes: https://opentelemetry.io/docs/zero-code/obi/setup/kubernetes/
- OBI distributed traces: https://opentelemetry.io/docs/zero-code/obi/distributed-traces/
- OBI v1.0 release notes: https://opentelemetry.io/blog/2026/obi-v1-release/
- OBI source: https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation
- kind: https://kind.sigs.k8s.io/
