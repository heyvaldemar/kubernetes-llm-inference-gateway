#!/usr/bin/env bash
# Does routing by prefix cache beat round-robin, on the same model servers?
#
#   tests/e2e.sh            (after scripts/up.sh; RESULTS=<dir> keeps the JSON;
#                           MODEL names the model the servers serve)
#
# The same multi-turn load, 32 conversations of 6 turns, goes once through a
# plain Service (kube-proxy picks a replica at random) and once through the
# llm-d router, twice each, in alternating order and with conversations no
# cache has seen. It requires:
#   - every image running in the cluster pinned in images.lock;
#   - every request answered, on both routes;
#   - through the router, a time to first token after the first turn (the
#     turns a cache can help) of at most RATIO_MAX of round-robin's, at the
#     median, in every round;
#   - through the router, a prefix cache hit rate at least HIT_GAIN_MIN above
#     round-robin's, in every round.
# The thresholds sit well inside what the simulator measures (about a third
# of the time and twice the hits), so a pass is not luck and a fail means the
# routing stopped working. tests/plants.tsv shows each check the break it is for.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="${RESULTS:-$ROOT/results}"
RATIO_MAX="${RATIO_MAX:-0.6}"
HIT_GAIN_MIN="${HIT_GAIN_MIN:-0.2}"
MODEL="${MODEL:-sim/model}"
mkdir -p "$RESULTS"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "OK: $*"; }

run() {  # run <label> <target> <seed>: one load, its JSON into $RESULTS
  if ! "$ROOT/scripts/run-load.sh" "$1" "$2" "$3" --model "$MODEL" > "$RESULTS/$1-$3.json"; then
    bad "$1 ($3): the load job failed or some requests failed: $(cut -c1-300 "$RESULTS/$1-$3.json")"
  fi
}

# What runs is what images.lock names, digest and all, including the images a
# chart brings in its own defaults, which no file in deploy/ shows.
running="$(kubectl get pods -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u)"
stray="$(grep -vxF -f <(sed -n 's/^[A-Z0-9_]*_IMAGE=//p' "$ROOT/images.lock") <<<"$running" || true)"
if [ -z "$running" ]; then
  bad "no pods running: run scripts/up.sh first"
elif [ -n "$stray" ]; then
  bad "images running that images.lock does not pin: $(paste -sd' ' - <<<"$stray")"
else
  ok "every image running is pinned in images.lock"
fi

ROUTER=http://router-epp:80
ROUNDROBIN=http://model-server-roundrobin:8000
run roundrobin "$ROUNDROBIN" a1
run router "$ROUTER" b1
run router "$ROUTER" a2
run roundrobin "$ROUNDROBIN" b2

python3 -I - "$RESULTS" "$RATIO_MAX" "$HIT_GAIN_MIN" <<'PY' || fail=1
import json, sys, os
d, ratio_max, gain_min = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
load = lambda n: json.load(open(os.path.join(d, n)))
rounds = [(load("roundrobin-a1.json"), load("router-b1.json")), (load("roundrobin-b2.json"), load("router-a2.json"))]
bad = 0
for i, (rr, rt) in enumerate(rounds, 1):
    for r in (rr, rt):
        if r.get("failed", 1) != 0 or r.get("job") != "complete":
            print(f"FAIL: round {i} {r.get('label')}: {r.get('failed')} failed requests, job {r.get('job')}"); bad = 1
    try:
        a, b = rr["ttft_later_turns_ms"]["50"], rt["ttft_later_turns_ms"]["50"]
        ha, hb = rr["cache_hit_rate"], rt["cache_hit_rate"]
    except (KeyError, TypeError):
        print(f"FAIL: round {i}: a run has no measurements"); bad = 1; continue
    ratio = b / a
    line = (f"round {i}: TTFT after the first turn, median: round-robin {a:.0f} ms, router {b:.0f} ms "
            f"({ratio:.2f}x); prefix cache hits: round-robin {ha:.0%}, router {hb:.0%}")
    if ratio <= ratio_max:
        print(f"OK: {line}")
    else:
        print(f"FAIL: {line}: the router's TTFT is above {ratio_max}x round-robin's"); bad = 1
    if hb is not None and ha is not None and hb - ha >= gain_min:
        print(f"OK: round {i}: the router's hit rate is {hb - ha:+.0%} over round-robin's")
    else:
        print(f"FAIL: round {i}: the router's hit rate is not {gain_min:.0%} above round-robin's"); bad = 1
sys.exit(bad)
PY

[ "$fail" -eq 0 ] || { echo "Prefix-aware routing did not do what it promises." >&2; exit 1; }
echo "Prefix-aware routing beat round-robin in every round."
