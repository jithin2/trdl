# Local developer commands. CI runs the same steps (.github/workflows/pipeline.yml).
TAG ?= dev
KIND_CLUSTER ?= trdl

.PHONY: run test lint image e2e e2e-clean

run:            ## Run the app on :8080
	cd app && go run .

test:           ## Unit tests
	cd app && go vet ./... && go test -race -count=1 -cover ./...

lint:           ## Format, chart and script checks
	cd app && test -z "$$(gofmt -l .)"
	helm lint charts/trdl --set image.tag=lint -f deploy/poc/values.yaml
	shellcheck tests/e2e/*.sh infra/bootstrap/*.sh
	terraform -chdir=infra fmt -check -recursive

image:          ## Build the container image
	docker build --build-arg REVISION=$(TAG) -t trdl:$(TAG) app

e2e: image      ## Full end-to-end run on a local kind cluster
	kind get clusters | grep -qx $(KIND_CLUSTER) || kind create cluster --name $(KIND_CLUSTER) --config tests/e2e/kind-config.yaml
	kubectl wait --for=condition=Ready nodes --all --timeout=120s
	# A node can report Ready a moment before kind actually clears its
	# startup "not-ready:NoSchedule" taint, which can bunch all pods onto
	# whichever node clears first. Poll the taint itself, not a guessed delay.
	for i in $$(seq 1 60); do \\
	  remaining=$$(kubectl get nodes -o json | jq '[.items[].spec.taints // [] | .[] | select(.key=="node.kubernetes.io/not-ready" and .effect=="NoSchedule")] | length'); \\
	  [ "$$remaining" -eq 0 ] && break; \\
	  sleep 2; \\
	done
	kind load docker-image trdl:$(TAG) --name $(KIND_CLUSTER)
	helm upgrade --install trdl charts/trdl --namespace trdl --create-namespace \\
	  -f tests/e2e/values-kind.yaml --set image.tag=$(TAG) --wait --timeout 3m
	bash tests/e2e/smoke.sh
	bash tests/e2e/check-spread.sh
	bash tests/e2e/zero-downtime.sh

e2e-clean:      ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)
