#!/usr/bin/env bash
# Black-box checks of the HTTP contract.
#
#   tests/e2e/smoke.sh http://20.1.2.3        # against a public IP
#   tests/e2e/smoke.sh                        # port-forward to svc/trdl in namespace trdl
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-trdl}"
BASE_URL="${1:-}"
PF_PID=""

# shellcheck disable=SC2317,SC2329  # only called indirectly, by the EXIT trap below
cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -z "$BASE_URL" ]]; then
  kubectl -n "$NAMESPACE" port-forward svc/trdl 18080:80 >/dev/null 2>&1 &
  PF_PID=$!
  BASE_URL="http://127.0.0.1:18080"
fi

fail=0
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X "$1" "$BASE_URL$2"; }
check() { # name, expected, actual
  if [[ "$2" == "$3" ]]; then echo "PASS  $1"; else echo "FAIL  $1: expected '$2', got '$3'"; fail=1; fi
}

# A new Azure load balancer can take a minute before it forwards traffic.
for _ in $(seq 1 60); do
  [[ "$(status GET /healthz)" == "200" ]] && break
  sleep 2
done

check "GET / returns 42"            "42"  "$(curl -s --max-time 5 "$BASE_URL/")"
check "GET / status"                "200" "$(status GET /)"
check "HEAD / status"               "200" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -I "$BASE_URL/")"
check "GET /?x=1 ignores query"     "42"  "$(curl -s --max-time 5 "$BASE_URL/?x=1")"
check "POST / is 405"               "405" "$(status POST /)"
check "GET /unknown is 404"         "404" "$(status GET /unknown)"
check "GET /healthz is 200"         "200" "$(status GET /healthz)"
check "GET /readyz is 200"          "200" "$(status GET /readyz)"

exit "$fail"
