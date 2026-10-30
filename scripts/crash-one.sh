#!/usr/bin/env bash
# Crash one model-server replica the way an OOM kill or a segfault would:
# SIGKILL to the server process, from the kind node, with no termination grace.
# The pod stays and the kubelet restarts the container, as it would in
# production. Its address refuses connections until the server is back.
#
#   scripts/crash-one.sh [<kind node>]    prints "<pod> <unix ms of the kill>"
set -euo pipefail
NODE="${1:-${KIND_NODE:-${CLUSTER:-ilg}-control-plane}}"
# A replica whose server container is up and Ready: one still restarting
# from an earlier crash has no process to kill.
pod="$(kubectl get pods -l app=model-server \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].ready}{"\n"}{end}' \
  | awk '$2 == "true" {print $1; exit}')"
[ -n "$pod" ] || { echo "no Ready model-server replica to crash" >&2; exit 1; }
cid="$(docker exec "$NODE" crictl ps --label "io.kubernetes.pod.name=$pod" --name sim -q | head -1)"
pid="$(docker exec "$NODE" crictl inspect --output go-template --template '{{.info.pid}}' "$cid")"
docker exec "$NODE" kill -9 "$pid"
echo "$pod $(python3 -I -c 'import time; print(int(time.time()*1000))')"
