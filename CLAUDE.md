# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Online Boutique** is a Google Cloud microservices demo — a polyglot e-commerce app where 11 services communicate exclusively over gRPC. It is designed to demonstrate GKE, Cloud Service Mesh, OpenTelemetry, and related Google Cloud products. It is not a product; it is a reference architecture and demo.

## Architecture

All inter-service communication uses gRPC. The single source of truth for service contracts is `protos/demo.proto`. Each service has its own generated client stubs (do not edit generated files under `genproto/`).

| Service | Language | Role |
|---|---|---|
| `frontend` | Go | HTTP server; calls all other services; no auth/login |
| `checkoutservice` | Go | Orchestrates cart, payment, shipping, email |
| `cartservice` | C# | Cart storage in Redis |
| `productcatalogservice` | Go | Product list from a static JSON file |
| `shippingservice` | Go | Shipping cost estimates |
| `currencyservice` | Node.js | Currency conversion (highest QPS service) |
| `paymentservice` | Node.js | Mock credit card charging |
| `emailservice` | Python | Mock order confirmation emails |
| `recommendationservice` | Python | Product recommendations |
| `adservice` | Java (Gradle) | Context-based text ads |
| `shoppingassistantservice` | Python | Gemini + AlloyDB vector store; optional add-on |
| `loadgenerator` | Python/Locust | Synthetic traffic against the frontend |

`shoppingassistantservice` is an optional component requiring AlloyDB, Google Secret Manager, and Gemini — it is not deployed by default and has its own kustomize component at `kustomize/components/shopping-assistant/`.

## Running and deploying

**Local Kubernetes (Minikube/Kind/Docker Desktop):**
```sh
skaffold run                        # build images + deploy to current kubectl context
skaffold dev                        # same, but watches for changes and rebuilds
kubectl port-forward deployment/frontend 8080:8080
```

**GKE:**
```sh
skaffold run --default-repo=us-docker.pkg.dev/PROJECT_ID/microservices-demo
kubectl get service frontend-external   # get external IP
```

**Teardown:**
```sh
skaffold delete
```

Skaffold uses `kubernetes-manifests/` via Kustomize by default. The `release/kubernetes-manifests.yaml` is a pre-built single-file alternative for direct `kubectl apply`.

## Testing

Unit tests exist only for the Go services and C# cartservice:

```sh
# Go services with tests
cd src/shippingservice && go test
cd src/productcatalogservice && go test
cd src/frontend/validator && go test

# C# cartservice
dotnet test src/cartservice/
```

No test framework is configured for Node.js, Python, or Java services. CI runs unit tests then does a full deployment smoke test on GKE.

## Protobuf changes

If you modify `protos/demo.proto`, regenerate client stubs using the per-service `genproto.sh` scripts (e.g., `src/frontend/genproto.sh`). Each service manages its own generated code in its local `genproto/` directory.

## Deployment variations

Kustomize overlays in `kustomize/components/` provide opt-in features: Istio/Cloud Service Mesh, Memorystore (Redis), Spanner (cart), AlloyDB (shopping assistant), Google Cloud Operations (tracing/profiling), network policies, and Cymbal branding. Apply them by combining kustomize components — see `kustomize/` for examples.

Helm chart is in `helm-chart/`. Terraform for GKE cluster provisioning is in `terraform/`.
