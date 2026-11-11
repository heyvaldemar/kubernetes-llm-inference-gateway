#!/usr/bin/env bash
# Does the GPU run's apply get its time to stop (ADR 5)? gpu.yml runs
# Terraform under scripts/interrupt-after.py: past the limit SIGINT, so
# Terraform writes what it made to the state and releases the lock, and
# SIGKILL only if it has not ended a grace later. ubuntu-26.04's timeout,
# uutils 0.10.0, sends that SIGKILL a fraction of a second after the SIGINT
# whatever -k says. This holds the script to its promise on small numbers,
# and gpu.yml and the scripts to using it; tests/interrupt-after-plants.tsv
# breaks each promise once.
#
#   tests/interrupt-after.sh       (no cluster, no account: run in CI's lint job; bash 5)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IA=(python3 -I "$ROOT/scripts/interrupt-after.py")
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "OK: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# alive <pid>: running after half a second, not a zombie whose parent has not
# reaped it yet, as a process killed a moment ago can be.
alive() {
  local state
  for _ in 1 2 3 4 5; do
    kill -0 "$1" 2>/dev/null || return 1
    state="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" || return 1
    [ "$state" != Z ] || return 1
    sleep 0.1
  done
}

# run <guard seconds> <command...>: sets rc and ms. The guard, a SIGKILL to the
# script under test, bounds a hang and leaves rc empty when it fires.
run() {
  local guard=$1 start=$EPOCHREALTIME pid watch
  shift
  rm -f "$work/guard"
  "$@" 2>>"$work/stderr" &
  pid=$!
  { sleep "$guard"; touch "$work/guard"; kill -KILL "$pid"; } >/dev/null 2>&1 &
  watch=$!
  rc=0
  wait "$pid" || rc=$?
  kill "$watch" 2>/dev/null || true
  wait "$watch" 2>/dev/null || true
  ms=$(( (${EPOCHREALTIME/./} - ${start/./}) / 1000 ))
  if [ -e "$work/guard" ]; then rc=""; fi
}

run 10 "${IA[@]}" 5s 5s -- bash -c 'exit 7'
if [ "$rc" = 7 ] && [ "$ms" -lt 3000 ]; then ok "a command that ends in time keeps its status ($rc, $ms ms)"; else bad "a command that exits 7 in time gave '$rc' after $ms ms"; fi

run 10 "${IA[@]}" 5s 5s -- true
if [ "$rc" = 0 ]; then ok "a command that succeeds in time gives 0"; else bad "true gave '$rc'"; fi

run 10 "${IA[@]}" 5s 5s -- bash -c 'kill -TERM $$'
if [ "$rc" = 143 ]; then ok "a command that dies of a signal of its own gives 128 and the signal ($rc)"; else bad "a command that died of SIGTERM gave '$rc', not 143"; fi

# Past the limit, with a cleanup that takes 2 s: the SIGINT must come, and
# then the cleanup must be waited for.
rm -f "$work/cleaned"
run 15 "${IA[@]}" 1s 6s -- bash -c "trap 'sleep 2; echo done > \"$work/cleaned\"; exit 3' INT; while :; do sleep 0.1; done"
if [ "$rc" = 124 ] && [ -e "$work/cleaned" ] && [ "$ms" -ge 2900 ] && [ "$ms" -lt 6000 ]; then
  ok "past the limit the command gets SIGINT, its 2 s cleanup is waited for, and the status is 124 ($ms ms)"
else
  bad "past the limit: status '$rc', cleanup $([ -e "$work/cleaned" ] && echo finished || echo 'cut off or never started'), after $ms ms"
fi

# A command that ignores SIGINT, with a child of its own: both are killed
# when the grace runs out, and not before.
rm -f "$work/child"
run 15 "${IA[@]}" 1s 2s -- bash -c "trap '' INT; sleep 60 >/dev/null 2>&1 & echo \$! > \"$work/child\"; wait"
left=""
if [ -s "$work/child" ] && alive "$(cat "$work/child")"; then left=yes; kill -KILL "$(cat "$work/child")" 2>/dev/null || true; fi
if [ "$rc" = 137 ] && [ -z "$left" ] && [ "$ms" -ge 2900 ] && [ "$ms" -lt 6000 ]; then
  ok "a command that ignores SIGINT is killed with its process group when the grace runs out, status 137 ($ms ms)"
else
  bad "a command that ignores SIGINT: status '$rc' after $ms ms, its child $([ -n "$left" ] && echo 'left running' || echo gone)"
fi

# The GPU run's apply runs under the script, and nothing in a workflow or a
# script asks coreutils' timeout for a signal or a kill after one.
if grep -Eq '^ +python3 -I scripts/interrupt-after\.py 30m 3m -- terraform -chdir=eks apply ' "$ROOT/.github/workflows/gpu.yml"; then
  ok "gpu.yml applies under scripts/interrupt-after.py, 30m then 3m"
else
  bad "gpu.yml does not apply under scripts/interrupt-after.py 30m 3m"
fi
found="$(cd "$ROOT" && grep -rnE '(^|[^[:alnum:]_.-])timeout +(-[^ ]+ +)*(-[ks]|--kill-after|--signal)' .github scripts tests 2>/dev/null \
  | grep -v -E '^(scripts/interrupt-after\.py|tests/interrupt-after\.sh|tests/interrupt-after-plants\.tsv):' \
  | grep -v -E '^[^:]+:[0-9]+: *#' || true)"
if [ -z "$found" ]; then
  ok "no workflow or script asks timeout for a signal or a kill after one"
else
  bad "timeout with a signal or -k, which uutils' timeout on ubuntu-26.04 follows with SIGKILL at once: $found"
fi

[ "$fail" -eq 0 ] || { cat "$work/stderr" >&2; echo "The GPU run's apply could be killed before Terraform stops." >&2; exit 1; }
echo "The GPU run's apply is interrupted in time, given its grace, and killed only after it."
