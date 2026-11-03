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
#
# The GPU run (ADR 5) judges its time at RATIO_PERCENTILE 90: on one GPU four
# replicas share, the median moves with the card more than with the routing,
# and the tail is where a miss lands. JUDGE_ONLY=1 judges the results already
# in RESULTS and runs nothing, which is how tests/gpu-judge.sh replays the GPU
# runs' saved results against gpu.yml's thresholds.
#
# E2E_RESULTS=<file> also writes what the run printed as JSON, every OK and
# FAIL line a check and every MEASURED line a measurement, for the status
# workflow (scripts/status.py). The kind e2e workflow sets it; nothing else does.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="${RESULTS:-$ROOT/results}"
RATIO_MAX="${RATIO_MAX:-0.6}"
HIT_GAIN_MIN="${HIT_GAIN_MIN:-0.2}"
RATIO_PERCENTILE="${RATIO_PERCENTILE:-50}"
JUDGE_ONLY="${JUDGE_ONLY:-0}"
MODEL="${MODEL:-sim/model}"
mkdir -p "$RESULTS"
fail=0
said="$(mktemp)"  # every OK, FAIL and MEASURED line, for E2E_RESULTS
trap 'rm -f "$said"' EXIT
bad() { echo "FAIL: $*" >&2; echo "FAIL: ${*//$'\n'/ }" >>"$said"; fail=1; }
ok() { echo "OK: $*"; echo "OK: $*" >>"$said"; }

run() {  # run <label> <target> <seed>: one load, its JSON into $RESULTS
  if ! "$ROOT/scripts/run-load.sh" "$1" "$2" "$3" --model "$MODEL" > "$RESULTS/$1-$3.json"; then
    bad "$1 ($3): the load job failed or some requests failed: $(cut -c1-300 "$RESULTS/$1-$3.json")"
  fi
}

if [ "$JUDGE_ONLY" != 1 ]; then
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
fi

python3 -I - "$RESULTS" "$RATIO_MAX" "$HIT_GAIN_MIN" "$RATIO_PERCENTILE" <<'PY' | tee -a "$said" || fail=1
import json, sys, os
d, ratio_max, gain_min, pct = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
measure = "median" if pct == "50" else f"{pct}th percentile"
load = lambda n: json.load(open(os.path.join(d, n)))
rounds = [(load("roundrobin-a1.json"), load("router-b1.json")), (load("roundrobin-b2.json"), load("router-a2.json"))]
bad = 0
seen = []  # (round-robin ms, router ms, ratio, round-robin hits, router hits), per round measured
for i, (rr, rt) in enumerate(rounds, 1):
    answered = True
    for r in (rr, rt):
        if r.get("failed", 1) != 0 or r.get("job") != "complete":
            print(f"FAIL: round {i} {r.get('label')}: {r.get('failed')} failed requests, job {r.get('job')}"); bad = 1
            answered = False
    if answered:
        print(f"OK: round {i}: every request answered, {rr.get('ok')} through round-robin, {rt.get('ok')} through the router")
    try:
        a, b = rr["ttft_later_turns_ms"][pct], rt["ttft_later_turns_ms"][pct]
        ha, hb = rr["cache_hit_rate"], rt["cache_hit_rate"]
    except (KeyError, TypeError):
        print(f"FAIL: round {i}: a run has no measurements"); bad = 1; continue
    ratio = b / a
    seen.append((a, b, ratio, ha, hb))
    line = (f"round {i}: TTFT after the first turn, {measure}: round-robin {a:.0f} ms, router {b:.0f} ms "
            f"({ratio:.2f}x); prefix cache hits: round-robin {ha:.0%}, router {hb:.0%}")
    if ratio <= ratio_max:
        print(f"OK: {line}")
    else:
        print(f"FAIL: {line}: the router's TTFT is above {ratio_max}x round-robin's"); bad = 1
    if hb is not None and ha is not None and hb - ha >= gain_min:
        print(f"OK: round {i}: the router's hit rate is {hb - ha:+.0%} over round-robin's")
    else:
        print(f"FAIL: round {i}: the router's hit rate is not {gain_min:.0%} above round-robin's"); bad = 1

# What the rounds measured, low to high, for the status page and its badges:
# the text before ": " names the badge, the text before " (" is its value.
def span(xs, fmt):
    lo, hi = fmt.format(min(xs)), fmt.format(max(xs))
    return lo if lo == hi else f"{lo}–{hi}"
if seen:
    print(f"MEASURED: router TTFT after the first turn: {span([s[2] for s in seen], '{:.2f}')}x round-robin's "
          f"({measure}, {span([s[1] for s in seen], '{:.0f}')} ms against {span([s[0] for s in seen], '{:.0f}')} ms)")
hits = [s for s in seen if s[3] is not None and s[4] is not None]
if hits:
    print(f"MEASURED: prefix cache hits: router {span([100 * s[4] for s in hits], '{:.0f}')}%, "
          f"round-robin {span([100 * s[3] for s in hits], '{:.0f}')}%")
sys.exit(bad)
PY

# A copy the status workflow reads (scripts/status.py), when one is asked for.
# A run that failed with no FAIL line of its own still counts a failed check.
if [ -n "${E2E_RESULTS:-}" ]; then
  python3 -I - "$said" "$fail" >"$E2E_RESULTS" <<'PY'
import json, sys
checks, measured = [], []
for line in open(sys.argv[1], encoding="utf-8"):
    kind, _, text = line.rstrip("\n").partition(": ")
    if kind in ("OK", "FAIL") and text:
        checks.append({"state": "PASS" if kind == "OK" else "FAIL", "name": text})
    elif kind == "MEASURED" and text:
        measured.append(text)
if sys.argv[2] != "0" and not any(c["state"] == "FAIL" for c in checks):
    checks.append({"state": "FAIL", "name": "the comparison stopped before it judged the results"})
json.dump({"checks": checks, "measured": measured}, sys.stdout, indent=2)
PY
fi

[ "$fail" -eq 0 ] || { echo "Prefix-aware routing did not do what it promises." >&2; exit 1; }
echo "Prefix-aware routing beat round-robin in every round."
