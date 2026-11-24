CLUSTER := obi-poc

# image tags: keep in sync with helm/shop/values.yaml
IMAGES := shop/payments:0.1.0 shop/inventory:0.1.0 shop/orders:0.1.0 shop/frontend:0.2.1 shop/loadgen:0.2.0

.PHONY: cluster nodes build load deploy status pf obs-repos obs grafana-pass obi obi-uninstall bpf-progs dashboards clean

## Phase 1: create the kind cluster (1 control-plane + 2 workers)
cluster:
	kind create cluster --config kind/kind-config.yaml --wait 120s

## Show nodes and their RAM use
nodes:
	kubectl get nodes -o wide
	docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' | grep $(CLUSTER)

## Phase 2: build all app images (tag -> folder apps/<name>)
build:
	@for img in $(IMAGES); do \
	  name=$$(echo $$img | cut -d/ -f2 | cut -d: -f1); \
	  echo "building $$img"; docker build -q -t $$img apps/$$name >/dev/null || exit 1; \
	done

## Copy app images into the kind nodes (postgres/redis are pulled by the nodes)
load:
	@for img in $(IMAGES); do kind load docker-image $$img --name $(CLUSTER) >/dev/null && echo "loaded $$img"; done

## Phase 3: install/upgrade the shop chart
deploy:
	helm upgrade --install shop ./helm/shop -n shop --create-namespace --reset-values --wait --timeout 5m

## Pods, placement, and last loadgen lines
status:
	kubectl -n shop get pods -o wide
	kubectl -n shop logs deploy/loadgen --tail=5

## Open the app at http://localhost:3000 (Ctrl+C to stop). The NodePort also works: http://localhost:8080
pf:
	kubectl -n shop port-forward svc/frontend 3000:3000

## Phase 4: Helm repos for the observability stack
obs-repos:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana-community https://grafana-community.github.io/helm-charts
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	helm repo update

## Phase 4: Prometheus + Grafana, Tempo, OTel Collector (pinned chart versions)
obs:
	helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 93.9.0 \
	  -n observability --create-namespace -f observability/values-kube-prometheus-stack.yaml --wait --timeout 10m
	helm upgrade --install tempo grafana-community/tempo --version 3.2.1 \
	  -n observability -f observability/values-tempo.yaml --wait --timeout 5m
	helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --version 0.182.0 \
	  -n observability -f observability/values-otel-collector.yaml --wait --timeout 5m

## Grafana admin password (user: admin)
grafana-pass:
	@kubectl -n observability get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo

## Phase 5: OBI DaemonSet (observe only: unprivileged, no context propagation, ns shop)
obi:
	helm upgrade --install obi open-telemetry/opentelemetry-ebpf-instrumentation --version 0.16.4 \
	  -n observability -f observability/values-obi.yaml --wait --timeout 5m

## Remove OBI (its eBPF programs are detached when the process exits)
obi-uninstall:
	helm uninstall obi -n observability

## List eBPF programs in the shared kernel, grouped by type (read-only)
bpf-progs:
	@docker build -q -t local/bpftool:alpine3.20 tools/bpftool >/dev/null
	@docker run --rm --privileged --pid=host local/bpftool:alpine3.20 -j prog show | \
	  python3 -c 'import json,sys,collections; p=json.load(sys.stdin); print(len(p), "programs:", dict(collections.Counter(x["type"] for x in p)))'

## Phase 6: load Grafana dashboards (ConfigMap with label grafana_dashboard=1 -> Grafana sidecar)
dashboards:
	kubectl -n observability create configmap shop-dashboards --from-file=observability/dashboards/ \
	  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

## Delete everything
clean:
	kind delete cluster --name $(CLUSTER)
