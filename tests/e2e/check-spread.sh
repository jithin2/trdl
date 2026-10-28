#!/usr/bin/env bash
# Checks that the pods run in three different zones.
set -euo pipefail

NAMESPACE="${NAMESPACE:-trdl}"

zones=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=trdl \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
  xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' |
  sort -u | wc -l)

if [[ "$zones" -ge 3 ]]; then
  echo "PASS  pods spread over $zones zones"
else
  echo "FAIL  pods are in $zones zone(s), expected 3"
  kubectl -n "$NAMESPACE" get pods -o wide
  exit 1
fi
