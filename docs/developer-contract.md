# Developer contract: what an app must do to run on this platform

This page is for the TRDL developer, and for anyone who brings another service to the same platform. The platform is AKS with the Helm chart in `charts/trdl`. The chart makes some promises (three replicas, spread over zones, rolling updates without errors). It can only keep them if the app follows the rules below.

TRDL already meets every MUST rule. Each rule says where to see it in the code.

## MUST rules

### 1. Ship one small container image, running as non-root

- Build from `app/Dockerfile`: a multi-stage build that ends in a distroless image with no shell.
- Run as a non-zero UID. The chart sets `runAsNonRoot: true`, so a root image will not start.
- Work with a read-only root filesystem. If you need scratch space, ask for an `emptyDir` volume on `/tmp`.
- Pin the base image version. Dependabot opens a PR when a new one comes out.

Why: a small image with no shell gives an attacker very little to use, and starts fast on a new node.

### 2. Listen on the port in `PORT`

The chart sets `PORT=8080`. Read it at start. Use a port above 1024, because a non-root process cannot bind lower ports.

TRDL: `LoadConfig` in `app/main.go`.

### 3. Give two health endpoints, and keep them local

| Endpoint | Used by | Must answer 200 when | Must never check |
|---|---|---|---|
| `/healthz` | liveness and startup probe | the process is alive and not deadlocked | databases, other services, the network |
| `/readyz` | readiness probe | this pod can take traffic now | shared dependencies |

Why the rule about dependencies: if `/readyz` checks a shared database, one short database problem makes every pod "not ready" at the same moment. The Service then has zero endpoints and the whole service is down, even though the pods were fine. A failing dependency should only fail the requests that need it.

If your app needs a slow dependency before it can start (for example a cache warm-up), check it once at start time. The startup probe gives you up to 30 seconds (`failureThreshold: 15` x `periodSeconds: 2`). Ask for more if you need it.

TRDL: `app/handler.go`.

### 4. Shut down cleanly on SIGTERM

When a pod is stopped (rollout, scale-down, node upgrade), Kubernetes sends SIGTERM and removes the pod from the Service at the same time. These two things happen in parallel, so for a few seconds new requests can still arrive. The app must:

1. Mark itself not ready (`/readyz` returns 503).
2. Keep serving for `SHUTDOWN_DELAY` (default 5s) while the endpoint removal spreads through the cluster.
3. Stop taking new connections, finish the open requests within `SHUTDOWN_TIMEOUT` (default 15s), and exit with code 0.

Delay plus timeout must stay below `terminationGracePeriodSeconds` (30s). After that the kubelet sends SIGKILL.

The e2e test `tests/e2e/zero-downtime.sh` checks this: it sends requests in a loop while all pods are replaced, and fails on a single error.

TRDL: `Serve` in `app/main.go`.

### 5. Be stateless

Keep no state in memory or on disk between requests. Any replica must be able to answer any request. Session data, uploads and caches that must survive go to a managed service (for example Azure Cache for Redis or Blob Storage).

Why: pods are replaced on every deploy, moved during node upgrades and added by the autoscaler.

### 6. Log to stdout as JSON, one line per event

No log files. The node's log agent collects container output. Use one JSON object per line, so fields like `status` and `path` can be queried.

TRDL: `log/slog` JSON handler, one access log line per request. Probe calls are not logged.

### 7. Read config from environment variables and fail fast

- All settings come from environment variables set in the chart values.
- Validate them at start. On a bad value, log the reason and exit non-zero. Never fall back to a default in silence.
- Secrets never go in the image, in git or in plain values files.

Why fail fast: a pod that exits at start never becomes ready. The rollout stops, Helm rolls back, and the old version keeps serving. A pod that starts with a wrong value can serve wrong answers for a long time before anyone notices.

TRDL: `LoadConfig` returns an error for `PORT=abc` or `SHUTDOWN_DELAY=-1s`, and `main` exits with code 2.

### 8. Declare resources and stay inside them

- Set CPU and memory requests. The scheduler places pods with them, and the HPA scales on CPU as a percentage of the request.
- Set a memory limit. Going over it gets the container killed (OOMKilled).
- No CPU limit by default: a CPU limit throttles the app even when the node has idle CPU. Add one only if the app can starve its neighbours.

For Go apps the chart sets `GOMEMLIMIT` from the memory limit, so the garbage collector works harder before the limit is hit.

### 9. Keep two versions compatible

During a rolling update the old and the new version answer traffic at the same time for a short while. A change to an API, a message format or a database schema must work with both versions. Make breaking changes in two releases: first add the new field or table, then remove the old one in the next release.

### 10. Keep the tests green

- Unit tests run with `go test -race` on every PR.
- `tests/e2e/smoke.sh` describes the public HTTP contract. If you change public behaviour, change the smoke test in the same PR.

## SHOULD rules (needed before production)

- **Metrics**: expose `/metrics` in Prometheus format with request count, latency histogram and errors by status code. This feeds the SLO alerts.
- **Tracing**: pass on the W3C `traceparent` header and export spans with OpenTelemetry.
- **Outbound calls**: the NetworkPolicy blocks all egress, because TRDL calls nothing. If your app needs DNS, a database or an API, add an egress rule to the chart in the same PR. Put a timeout on every outbound call.
- **Secrets**: read them from Azure Key Vault through workload identity, not from Kubernetes Secrets in git.

## What the platform gives you in return

| You get | Made by |
|---|---|
| 3 replicas, one per availability zone | Deployment, `topologySpreadConstraints` |
| A stable public IP that survives redeploys | Service type LoadBalancer, static public IP from Terraform |
| Scale out from 3 to 10 pods on CPU | HorizontalPodAutoscaler |
| At most one pod down during node upgrades | PodDisruptionBudget |
| Rollouts that never drop below 3 ready pods | `maxUnavailable: 0`, `maxSurge: 1` |
| Automatic rollback if the new version never gets ready | `helm upgrade --wait --rollback-on-failure` |
| No secrets in CI, no admin kubeconfig | GitHub OIDC to a managed identity, Azure RBAC for Kubernetes |

## How to extend TRDL

Example: add a JSON endpoint `GET /v1/answer` that returns `{"answer":42}`.

1. Add the route in `app/handler.go`:

   ```go
   mux.HandleFunc("GET /v1/answer", func(w http.ResponseWriter, _ *http.Request) {
       w.Header().Set("Content-Type", "application/json")
       _, _ = w.Write([]byte(`{"answer":42}` + "\n"))
   })
   ```

2. Add a row to the table in `TestRoutes` in `app/main_test.go`.
3. Add a check to `tests/e2e/smoke.sh`.
4. Open a PR. The pipeline runs unit tests, builds the image, runs the kind e2e tests and, after merge, deploys.

Nothing in the chart or the infrastructure changes for a new endpoint.

### Using another language

The rules do not depend on Go. The same contract in other stacks:

| Rule | Python (gunicorn) | Node.js |
|---|---|---|
| Port | `--bind 0.0.0.0:$PORT` | `server.listen(process.env.PORT)` |
| Graceful shutdown | `--graceful-timeout 15`, plus a short sleep in a SIGTERM handler | on `SIGTERM`: set not ready, wait, then `server.close()` |
| JSON logs | `python-json-logger` | `pino` |

## Checklist for a pull request

- [ ] Runs as non-root with a read-only root filesystem
- [ ] `/healthz` and `/readyz` answer, and check nothing outside the pod
- [ ] SIGTERM drain works (the zero-downtime e2e test passes)
- [ ] No local state, no log files
- [ ] New config is an environment variable, validated at start
- [ ] Requests and memory limit fit the new code
- [ ] Old and new version can run side by side
- [ ] Unit tests and smoke test cover the change
