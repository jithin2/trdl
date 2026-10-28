#!/usr/bin/env bash
# Proves that a rolling update drops no requests.
# A client pod calls the Service in a loop while every TRDL pod is replaced.
# Any answer other than 42 fails the test.
set -euo pipefail

NAMESPACE="${NAMESPACE:-trdl}"
DURATION="${DURATION:-90}"   # seconds of load, longer than a full rollout
JOB=trdl-load

kubectl -n "$NAMESPACE" delete job "$JOB" --ignore-not-found >/dev/null

kubectl -n "$NAMESPACE" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:8.11.1
          command: ["/bin/sh", "-c"]
          args:
            - |
              end=\$(( \$(date +%s) + $DURATION )); ok=0; fail=0
              while [ \$(date +%s) -lt \$end ]; do
                body=\$(curl -s --max-time 2 http://trdl.$NAMESPACE.svc.cluster.local/)
                if [ "\$body" = "42" ]; then ok=\$((ok+1)); else fail=\$((fail+1)); echo "bad answer: '\$body'"; fi
                sleep 0.05
              done
              echo "ok=\$ok fail=\$fail"
              [ "\$fail" -eq 0 ] && [ "\$ok" -gt 0 ]
EOF

kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l job-name="$JOB" --timeout=120s
sleep 5

echo "Rolling restart while the load runs"
kubectl -n "$NAMESPACE" rollout restart deployment/trdl
kubectl -n "$NAMESPACE" rollout status deployment/trdl --timeout=180s

echo "Waiting for the load job to finish"
for _ in $(seq 1 $((DURATION + 60))); do
  succeeded=$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.succeeded}')
  failed=$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.failed}')
  [[ "${succeeded:-0}" -ge 1 || "${failed:-0}" -ge 1 ]] && break
  sleep 1
done

kubectl -n "$NAMESPACE" logs job/"$JOB" | tail -n 20
if [[ "${succeeded:-0}" -ge 1 ]]; then
  echo "PASS  no failed requests during the rolling update"
else
  echo "FAIL  requests failed during the rolling update"
  exit 1
fi
