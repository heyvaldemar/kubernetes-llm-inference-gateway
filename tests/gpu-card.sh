#!/usr/bin/env bash
# Does the GPU run name the card it ran on (ADR 5)? scripts/eks.sh card is
# given the instance type the GPU node says it is and the GPU nvidia-smi
# names inside a model server, and must give the L4's name for an L4 on a
# g6.xlarge, the A10G's fallback name for an A10G on a g5.xlarge, and refuse
# every other pairing. A run that says L4 while it ran on an A10G is the
# break tests/gpu-card-plants.tsv plants.
#
#   tests/gpu-card.sh       (no cluster, no account: run in CI's lint job)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

expect() {  # expect <instance type> <GPU name> <the card's name, or REFUSED>
  local got rc
  got="$("$ROOT/scripts/eks.sh" card "$1" "$2" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$3" = REFUSED ]; then
    if [ "$rc" -ne 0 ]; then echo "OK: a $1 whose GPU says '$2' is refused"; else echo "FAIL: a $1 whose GPU says '$2' is called '$got'"; fail=1; fi
  elif [ "$rc" -eq 0 ] && [ "$got" = "$3" ]; then
    echo "OK: a $1 whose GPU says '$2' is called '$got'"
  else
    echo "FAIL: a $1 whose GPU says '$2' is called '$got', not '$3'"; fail=1
  fi
}

expect g6.xlarge "NVIDIA L4" "NVIDIA L4 (g6.xlarge)"
expect g5.xlarge "NVIDIA A10G" "NVIDIA A10G (g5.xlarge), fallback: no L4 in any zone"
expect g6.xlarge "NVIDIA A10G" REFUSED
expect g5.xlarge "NVIDIA L4" REFUSED
expect g4dn.xlarge "Tesla T4" REFUSED

[ "$fail" -eq 0 ] || { echo "The GPU run could name a card it did not run on." >&2; exit 1; }
echo "The GPU run names the card it ran on, and only that one."
