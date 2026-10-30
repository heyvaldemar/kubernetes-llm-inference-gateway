#!/usr/bin/env bash
# Run the load generator inside the cluster against one route, and add what
# the model servers themselves say about their prefix caches during the run.
#
#   scripts/run-load.sh <label> <target URL> <seed> [loadgen args...]
#
# Prints one JSON line: the load generator's summary plus "cache_hit_rate",
# the share of prompt tokens the four replicas found already cached
# (vllm:prefix_cache_hits_total / vllm:prefix_cache_queries_total, as deltas
# over the run), and the prompt and output tokens they counted
# (vllm:prompt_tokens_total, vllm:generation_tokens_total), which the GPU
# run prices. Exits non-zero if the job fails or any request failed.
set -euo pipefail
LABEL="${1:?usage: run-load.sh <label> <target> <seed> [args]}"
TARGET="${2:?usage: run-load.sh <label> <target> <seed> [args]}"
SEED="${3:?usage: run-load.sh <label> <target> <seed> [args]}"
shift 3
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/images.lock"
NS="${NS:-default}"
JOB="load-${LABEL}-$(date +%s)"

# One line per model-server pod: "<pod> <hits> <queries> <prompt> <output>",
# read through the API server's pod proxy, so nothing but kubectl is needed
# on the host. The counts are taken over pods present at both ends of the
# run, so a replica that dies or is replaced mid-run neither adds nor removes
# counts. Each metric by its exact name: vLLM also exports
# vllm:prompt_tokens_cached_total and others that start the same way.
counters() {
  local pod
  for pod in $(kubectl -n "$NS" get pods -l app=model-server -o jsonpath='{.items[*].metadata.name}'); do
    kubectl -n "$NS" get --raw "/api/v1/namespaces/$NS/pods/$pod:8000/proxy/metrics" 2>/dev/null \
      | awk -v p="$pod" '{n = $1; sub(/\{.*/, "", n)}
                         n == "vllm:prefix_cache_hits_total" {h += $2} n == "vllm:prefix_cache_queries_total" {q += $2}
                         n == "vllm:prompt_tokens_total" {i += $2} n == "vllm:generation_tokens_total" {o += $2}
                         END {printf "%s %.0f %.0f %.0f %.0f\n", p, h+0, q+0, i+0, o+0}'
  done
}

kubectl -n "$NS" create configmap loadgen --from-file=loadgen.py="$ROOT/loadgen/loadgen.py" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
before="$(counters)"

args_json="$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
  --target "$TARGET" --label "$LABEL" --seed "$SEED" "$@")"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  labels: {app: loadgen}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: {app: loadgen}
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: $PYTHON_IMAGE
          command: ["python3", "-I", "/loadgen/loadgen.py"]
          args: $args_json
          volumeMounts: [{name: loadgen, mountPath: /loadgen}]
          resources:
            requests: {cpu: 200m, memory: 64Mi}
            limits: {memory: 256Mi}
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 65534
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
      volumes: [{name: loadgen, configMap: {name: loadgen}}]
EOF
# Complete or Failed, whichever comes first; a hang ends at the timeout.
kubectl -n "$NS" wait --for=condition=Complete "job/$JOB" --timeout="${LOAD_TIMEOUT:-900s}" >/dev/null 2>&1 &
wc=$!
kubectl -n "$NS" wait --for=condition=Failed "job/$JOB" --timeout="${LOAD_TIMEOUT:-900s}" >/dev/null 2>&1 &
wf=$!
status=failed
while kill -0 "$wc" 2>/dev/null && kill -0 "$wf" 2>/dev/null; do sleep 2; done
if ! kill -0 "$wc" 2>/dev/null && wait "$wc"; then status=complete; fi
kill "$wc" "$wf" 2>/dev/null || true

summary="$(kubectl -n "$NS" logs "job/$JOB" 2>/dev/null | tail -n 1)"
after="$(counters)"
python3 -I - "$summary" "$before" "$after" "$status" <<'PY'
import json, sys
try:
    s = json.loads(sys.argv[1])
except ValueError:
    s = {"label": "unknown", "error": "no summary from the load job", "raw": sys.argv[1][-300:]}
def table(text):
    return {f[0]: [int(x) for x in f[1:]] for f in (l.split() for l in text.splitlines() if l.strip())}
b, a = table(sys.argv[2]), table(sys.argv[3])
both = set(a) & set(b)
hits, queries, prompt, output = (sum(a[p][i] - b[p][i] for p in both) for i in range(4))
s["cache_hit_rate"] = round(hits / queries, 3) if queries else None
s["prompt_tokens"] = prompt
s["output_tokens"] = output
s["replicas_counted"] = len(both)
s["job"] = sys.argv[4]
print(json.dumps(s))
PY
[ "$status" = complete ]
