#!/usr/bin/env bash
# Bring up (or bring back to its starting state) the cluster the tests run on:
# kind, the InferencePool CRD, four simulated model servers, the round-robin
# Service, and the llm-d router. Safe to run again on a cluster it made: it
# applies what changed and restarts the model servers, so every test starts
# with every prefix cache empty.
#
#   scripts/up.sh            CLUSTER, KUBECONFIG and ROUTER_VALUES may be set
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/images.lock"
CLUSTER="${CLUSTER:-ilg}"
ROUTER_VALUES="${ROUTER_VALUES:-$ROOT/deploy/router-values.yaml}"
say() { printf '== %s\n' "$*"; }

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  say "kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --config "$ROOT/cluster/kind.yaml" --wait 120s >/dev/null
fi

say "the InferencePool CRD, Gateway API Inference Extension $GAIE_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$GAIE_VERSION/v1-manifests.yaml" >/dev/null

say "four model servers (llm-d-inference-sim) and the round-robin Service"
kubectl apply -f "$ROOT/deploy/model-server.yaml" >/dev/null

say "the llm-d router ($ROUTER_CHART $ROUTER_CHART_VERSION)"
helm upgrade --install router "$ROUTER_CHART" --version "$ROUTER_CHART_VERSION" \
  -f "$ROUTER_VALUES" --wait --timeout 5m >/dev/null

# Empty caches for every test: a restart is the only reset the simulator has.
kubectl rollout restart deploy/model-server >/dev/null
kubectl rollout status deploy/model-server --timeout=180s >/dev/null
# The EPP reads its plugins from a ConfigMap at start, and the chart puts no
# checksum of it on the pod, so `helm upgrade` with new plugins leaves the
# old ones running. Restart it every time, or a test of a changed config
# measures the previous one (the plant "no prefix-cache affinity" went
# unnoticed until this line).
kubectl rollout restart deploy/router-epp >/dev/null
kubectl rollout status deploy/router-epp --timeout=180s >/dev/null
# Exactly four replicas, all Ready, and none of the old ones still shutting
# down: a terminating pod matches the label too, and the router would see it.
settled=false
for _ in $(seq 1 60); do
  states="$(kubectl get pods -l app=model-server \
    -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].ready}{"\n"}{end}')"
  if [ "$(grep -c . <<<"$states")" -eq 4 ] && ! grep -qv '^|true$' <<<"$states"; then settled=true; break; fi
  sleep 2
done
$settled || { echo "the model servers did not settle at four Ready replicas" >&2; exit 1; }
# The router learns the replicas from the InferencePool; give it a moment to
# see the four new ones before the first request.
sleep 5
say "up: $(kubectl get pods -l app=model-server --no-headers | wc -l | tr -d ' ') model servers, router $(kubectl get deploy router-epp -o jsonpath='{.status.readyReplicas}')/1"
