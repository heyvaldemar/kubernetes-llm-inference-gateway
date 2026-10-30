#!/usr/bin/env bash
# What each route does when one of four replicas fails, in three ways:
#   sick         it answers every completion at once with an error while its
#                /health stays fine (deploy/sick-replica.yaml beside three
#                regular replicas), probed at 10, 50 and 150 requests a second;
#   unreachable  packets to it are dropped for HOLD seconds while Kubernetes
#                still calls it Ready, as with a node gone quiet;
#   crashed      its server process is SIGKILLed (scripts/crash-one.sh) and
#                the kubelet restarts it.
# Each through the llm-d router and through the round-robin Service, with the
# open-loop probe (loadgen/probe.py): requests arrive on schedule, as from
# independent users, whatever happened to the ones before.
#
#   tests/failure-modes.sh       (after scripts/up.sh; RESULTS=<dir> keeps the JSON)
#
# This records what happens; it does not judge the router. It fails only when
# a scenario did not happen as designed, which round-robin shows, since what it
# does is known: about a quarter of its requests fail against the sick replica,
# some stall while one is unreachable, and a crashed replica is restarted.
# tests/failure-plants.tsv shows each of those checks the break it exists for.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/images.lock"
RESULTS="${RESULTS:-$ROOT/results}"
NODE="${KIND_NODE:-${CLUSTER:-ilg}-control-plane}"
HOLD="${HOLD:-6}"
CHAIN=FORWARD   # pod-to-pod traffic on the node crosses FORWARD; kubelet's probes do not
ROUTER=http://router-epp:80
ROUNDROBIN=http://model-server-roundrobin:8000
mkdir -p "$RESULTS"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }

dropped=""
restore() {
  [ -z "$dropped" ] || docker exec "$NODE" iptables -D "$CHAIN" -d "$dropped" -j DROP 2>/dev/null || true
  kubectl delete -f "$ROOT/deploy/sick-replica.yaml" --ignore-not-found >/dev/null 2>&1 || true
  kubectl scale deploy/model-server --replicas=4 >/dev/null 2>&1 || true
}
trap restore EXIT

settle() {   # four Ready model-server pods, none of them terminating
  local states
  for _ in $(seq 1 90); do
    states="$(kubectl get pods -l app=model-server \
      -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}')"
    if [ "$(grep -c . <<<"$states")" -eq 4 ] && ! grep -qv '^|true$' <<<"$states"; then
      sleep 5   # the router learns the replicas from the InferencePool
      return 0
    fi
    sleep 2
  done
  bad "the model servers did not settle at four Ready replicas"; return 1
}

restarts() { kubectl get pods -l app=model-server -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s += $1} END {print s + 0}'; }

# probe <name> <target> <rate> <seconds> [<action> <after seconds>]: the probe
# as a Job, its JSON into $RESULTS/fm-<name>.json; an action, if given, runs
# that many seconds after the probe's pod starts and writes its own times.
probe() {
  local name="$1" target="$2" rate="$3" secs="$4" action="${5:-}" after="${6:-0}" job
  job="probe-$name-$(date +%s)"
  kubectl create configmap probe --from-file=probe.py="$ROOT/loadgen/probe.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  labels: {app: probe}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: {app: probe}
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: $PYTHON_IMAGE
          command: ["python3", "-I", "/probe/probe.py"]
          args: ["--target", "$target", "--rate", "$rate", "--seconds", "$secs"]
          volumeMounts: [{name: probe, mountPath: /probe}]
          resources:
            requests: {cpu: 200m, memory: 64Mi}
            limits: {memory: 256Mi}
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 65534
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
      volumes: [{name: probe, configMap: {name: probe}}]
EOF
  kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l job-name="$job" --timeout=120s >/dev/null
  if [ -n "$action" ]; then sleep "$after"; "$action" "$name"; fi
  kubectl wait --for=condition=Complete "job/$job" --timeout=180s >/dev/null || bad "the probe $name did not finish"
  kubectl logs "job/$job" | tail -n 1 > "$RESULTS/fm-$name.json"
}

drop_one() {   # drop_one <name>: packets to one replica dropped for HOLD seconds
  dropped="$(kubectl get pods -l app=model-server -o jsonpath='{.items[0].status.podIP}')"
  docker exec "$NODE" iptables -I "$CHAIN" -d "$dropped" -j DROP
  local from; from="$(now_ms)"
  sleep "$HOLD"
  docker exec "$NODE" iptables -D "$CHAIN" -d "$dropped" -j DROP
  dropped=""
  echo "{\"from_ms\": $from, \"to_ms\": $(now_ms)}" > "$RESULTS/fm-$1.action.json"
}

crash() {      # crash <name>: SIGKILL one replica's server
  local before; before="$(restarts)"
  "$ROOT/scripts/crash-one.sh" "$NODE" >/dev/null
  echo "{\"at_ms\": $(now_ms), \"restarts_before\": $before}" > "$RESULTS/fm-$1.action.json"
}

echo "== sick: three regular replicas and one that fails fast"
kubectl scale deploy/model-server --replicas=3 >/dev/null
kubectl apply -f "$ROOT/deploy/sick-replica.yaml" >/dev/null
kubectl rollout status deploy/model-server --timeout=180s >/dev/null
kubectl rollout status deploy/model-server-sick --timeout=180s >/dev/null
settle
for rate in 10 50 150; do
  probe "sick-router-$rate" "$ROUTER" "$rate" 8
  probe "sick-roundrobin-$rate" "$ROUNDROBIN" "$rate" 8
done
kubectl delete -f "$ROOT/deploy/sick-replica.yaml" >/dev/null
kubectl scale deploy/model-server --replicas=4 >/dev/null
settle

echo "== unreachable: packets to one replica dropped for ${HOLD} s"
for route in router roundrobin; do
  target="$ROUTER"; [ "$route" = roundrobin ] && target="$ROUNDROBIN"
  probe "unreachable-$route" "$target" 50 $((HOLD + 6)) drop_one 3
  settle
done

echo "== crashed: one replica's server SIGKILLed"
for route in router roundrobin; do
  target="$ROUTER"; [ "$route" = roundrobin ] && target="$ROUNDROBIN"
  probe "crashed-$route" "$target" 50 8 crash 3
  settle
  after="$(restarts)"
  before="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["restarts_before"])' "$RESULTS/fm-crashed-$route.action.json")"
  [ "$after" -gt "$before" ] || bad "crashed ($route): no model server restarted, so nothing crashed"
done

python3 -I - "$RESULTS" <<'PY' || fail=1
import json, os, sys
d = sys.argv[1]
load = lambda n: json.load(open(os.path.join(d, "fm-%s.json" % n)))
act = lambda n: json.load(open(os.path.join(d, "fm-%s.action.json" % n)))
STALL = 1.0   # an answer slower than this, against about 0.1 s normally, waited on the failure
bad = 0
out = {"sick": {}, "unreachable": {}, "crashed": {}}
rows = ["| Failure | Requests a second | llm-d router | Round-robin Service |", "|---|---|---|---|"]

def failed(rs):
    return sum(1 for r in rs if r[1] != 200)

for rate in (10, 50, 150):
    cell = {}
    for route in ("router", "roundrobin"):
        rs = load("sick-%s-%d" % (route, rate))["results"]
        cell[route] = {"sent": len(rs), "failed": failed(rs), "share": round(failed(rs) / len(rs), 3)}
    out["sick"][rate] = cell
    rows.append("| sick: fast errors, healthy to its probe | %d | %.0f%% of %d failed | %.0f%% of %d failed |" % (
        rate, 100 * cell["router"]["share"], cell["router"]["sent"], 100 * cell["roundrobin"]["share"], cell["roundrobin"]["sent"]))
    if not 0.10 <= cell["roundrobin"]["share"] <= 0.40:
        print("FAIL: sick at %d/s: round-robin lost %.0f%%, not about a quarter: the sick replica is not in the pool or not failing" % (rate, 100 * cell["roundrobin"]["share"]))
        bad = 1

for kind in ("unreachable", "crashed"):
    cell = {}
    for route in ("router", "roundrobin"):
        p, a = load("%s-%s" % (kind, route)), act("%s-%s" % (kind, route))
        rs = p["results"]
        if kind == "unreachable":
            lo, hi = a["from_ms"] / 1000, a["to_ms"] / 1000
            during = [r for r in rs if lo <= r[0] < hi]
            hurt = [r for r in during if r[1] != 200 or r[2] > STALL]
            cell[route] = {"sent_during": len(during), "stalled_or_failed": len(hurt),
                           "longest_s": max([r[2] for r in hurt], default=0), "hold_s": round(hi - lo, 1)}
        else:
            cell[route] = {"sent": len(rs), "failed": failed(rs)}
    out[kind] = cell
    if kind == "unreachable":
        hold = round(cell["router"]["hold_s"])
        f = lambda c: "%d of %d stalled or failed" % (c["stalled_or_failed"], c["sent_during"])
        rows.append("| unreachable for about %d s, still Ready | 50 | %s | %s |" % (hold, f(cell["router"]), f(cell["roundrobin"])))
        rr = cell["roundrobin"]
        if not rr["sent_during"] or rr["stalled_or_failed"] < 0.05 * rr["sent_during"]:
            print("FAIL: unreachable: round-robin noticed nothing while packets were dropped: the drop did not take effect")
            bad = 1
    else:
        f = lambda c: "%d of %d failed" % (c["failed"], c["sent"])
        rows.append("| crashed, restarted by the kubelet | 50 | %s | %s |" % (f(cell["router"]), f(cell["roundrobin"])))

json.dump(out, open(os.path.join(d, "failure-modes.json"), "w"), indent=1)
print("\n".join(rows))
sys.exit(bad)
PY

[ "$fail" -eq 0 ] || { echo "A failure scenario did not happen as designed." >&2; exit 1; }
echo "Every failure scenario happened as designed; the table above is what each route did."
