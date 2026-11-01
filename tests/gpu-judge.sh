#!/usr/bin/env bash
# Does the GPU run's comparison tell working routing from broken (ADR 5)?
# It replays the saved results of GPU runs (tests/fixtures/gpu/<run>/)
# through tests/e2e.sh's judgement, with the time threshold and percentile
# gpu.yml gives the GPU run, read from gpu.yml itself. Every run whose router
# worked must pass; the run whose router picked at random (plant
# random-picker) must fail, and must fail on time alone, with the hit-rate
# check switched off, so the time check is shown its break too.
#
#   tests/gpu-judge.sh      (no cluster, no account: run in CI's lint job)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$ROOT/.github/workflows/gpu.yml"
pct="$(sed -n 's/^ *RATIO_PERCENTILE: "\([0-9]*\)"$/\1/p' "$wf")"
max="$(sed -n 's/^ *RATIO_MAX: "\([0-9.]*\)"$/\1/p' "$wf")"
if [ -z "$pct" ] || [ -z "$max" ]; then
  echo "gpu.yml gives the comparison no RATIO_PERCENTILE or RATIO_MAX" >&2; exit 1
fi
echo "gpu.yml: the router's time to first token after the first turn, at the ${pct}th percentile, at most ${max} of round-robin's"
fail=0

judge() {  # judge <results dir> [hit gain]: pass or fail, as tests/e2e.sh rules
  if JUDGE_ONLY=1 RESULTS="$1" RATIO_PERCENTILE="$pct" RATIO_MAX="$max" HIT_GAIN_MIN="${2:-0.2}" \
       "$ROOT/tests/e2e.sh" >/dev/null 2>&1; then echo pass; else echo fail; fi
}

for d in "$ROOT"/tests/fixtures/gpu/*/; do
  run="$(basename "$d")"
  want="$(sed -n 1p "$d/expect")"; what="$(sed -n 2p "$d/expect")"
  got="$(judge "$d")"
  if [ "$got" = "$want" ]; then echo "OK: run $run, $what: $got"; else echo "FAIL: run $run, $what: $got, not $want"; fail=1; fi
  # A broken router must fail on time alone too: with the hit-rate check
  # switched off, nothing else stands between it and a pass.
  if [ "$want" = fail ]; then
    got="$(judge "$d" -1)"
    if [ "$got" = fail ]; then echo "OK: run $run fails on time alone"; else echo "FAIL: run $run passes the time check"; fail=1; fi
  fi
done

[ "$fail" -eq 0 ] || { echo "The GPU run's thresholds do not tell working routing from broken." >&2; exit 1; }
echo "The GPU run's thresholds pass every working router and fail the broken one."
