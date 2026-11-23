CLUSTER := obi-poc

.PHONY: cluster clean nodes

## Phase 1: create the kind cluster (1 control-plane + 2 workers)
cluster:
	kind create cluster --config kind/kind-config.yaml --wait 120s

## Show nodes and their RAM use
nodes:
	kubectl get nodes -o wide
	docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' | grep $(CLUSTER)

## Delete everything
clean:
	kind delete cluster --name $(CLUSTER)
