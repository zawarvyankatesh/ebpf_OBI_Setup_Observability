CLUSTER := obi-poc

# image tags: keep in sync with helm/shop/values.yaml
IMAGES := shop/payments:0.1.0 shop/inventory:0.1.0 shop/orders:0.1.0 shop/frontend:0.2.1 shop/loadgen:0.2.0

.PHONY: cluster nodes build load deploy status pf clean

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
	helm upgrade --install shop ./helm/shop -n shop --create-namespace --wait --timeout 5m

## Pods, placement, and last loadgen lines
status:
	kubectl -n shop get pods -o wide
	kubectl -n shop logs deploy/loadgen --tail=5

## Open the app at http://localhost:3000 (Ctrl+C to stop). The NodePort also works: http://localhost:8080
pf:
	kubectl -n shop port-forward svc/frontend 3000:3000

## Delete everything
clean:
	kind delete cluster --name $(CLUSTER)
