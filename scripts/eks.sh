#!/usr/bin/env bash
# eks.sh <preflight|sweep|unlock|reserve|gpu|check|tokens|diagnose|stop|residue|cost> - the
# parts of the GPU run (ADR 5) that are not Terraform and not the comparison.
# .github/workflows/gpu.yml calls them; each reads the environment it sets:
# AWS_REGION, TF_STATE_BUCKET, CLUSTER (the run's cluster name), RUN_ID.
#
#   preflight  before anything is billed: the role this run assumed, that its
#              trust names this repository, the account's GPU quota against
#              what already runs, the on-demand prices from AWS's price list,
#              and the most the run could cost if every job ran to its
#              timeout, which must stay within MAX_RUN_USD
#   sweep      destroy what an earlier run of this workflow left: any other
#              state under inference-runs/ that still holds resources
#   unlock     remove the lock a stopped Terraform left on this run's state
#   reserve    before anything else is made: an On-Demand Capacity
#              Reservation for one L4, tried in each of the run's zones until
#              one gives it, imported into the run's state, and the zone
#              written to the run's variables, so the apply makes the GPU
#              node in it
#   gpu        NVIDIA's device plugin, and the GPU node offering its L4 as four
#   check      after scripts/up.sh: four model servers, all on the GPU node,
#              all on the same L4, each serving the pinned model with weights
#              that matched their digests
#   tokens     what each route's output tokens cost, from the e2e's results
#              and the prices preflight read
#   diagnose   what the cluster looked like, when a step failed
#   stop       the node groups deleted, any instance of the run terminated
#              and its reservation cancelled by the AWS CLI: when a destroy
#              failed, so nothing bills while a person looks, and after every
#              destroy, for what the state never held
#   residue    after the destroy, anything still tagged with the run's
#              cluster, or with any earlier run of this project: none is the
#              only passing answer
#   cost       what the run cost, from each instance's own launch and
#              termination, the GPU from its reservation's start, and the
#              control plane from apply to destroy
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX=inference-runs
PROJECT=kubernetes-llm-inference-gateway
TAG=inference.heyvaldemar.com
GPU_LABEL="$TAG/accelerator=nvidia"
# The prices the price list does not carry per instance type, us-east-1: the
# EKS control plane on standard support, a public IPv4 address, and gp3
# storage a GB-month. The nodes' prices are read from the price list.
EKS_USD_PER_HOUR=0.10
IPV4_USD_PER_HOUR=0.005
GP3_USD_PER_GB_MONTH=0.08
say() { printf '== %s\n' "$*"; }

# price <instance type>: its on-demand Linux price an hour in the region,
# from the AWS Price List API (whose endpoint is in us-east-1).
price() {
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$1" "Type=TERM_MATCH,Field=regionCode,Value=$AWS_REGION" \
      "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
      "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
      "Type=TERM_MATCH,Field=licenseModel,Value=No License required" \
    --query PriceList --output json | python3 -I -c '
import json, sys
prices = set()
for product in json.load(sys.stdin):
    for term in json.loads(product).get("terms", {}).get("OnDemand", {}).values():
        for d in term["priceDimensions"].values():
            if d.get("unit") == "Hrs":
                prices.add(float(d["pricePerUnit"]["USD"]))
if len(prices) != 1:
    sys.exit("%s: the price list gave %s on-demand prices, not one" % (sys.argv[1], sorted(prices) or "no"))
print(prices.pop())' "$1"
}

# unlock <state key>: remove the lock a stopped Terraform left on a state
# (use_lockfile keeps it beside the state as <key>.tflock). Only for a state
# no Terraform holds: the run's own once its up job has ended, or an earlier
# run's. Run 41067783938's apply was killed by its step's timeout and left
# one, which refused both of the down job's destroys.
unlock() {
  if aws s3api head-object --bucket "$TF_STATE_BUCKET" --key "$1.tflock" >/dev/null 2>&1; then
    aws s3 rm --quiet "s3://$TF_STATE_BUCKET/$1.tflock"
    say "removed the lock a stopped Terraform left on $1"
  fi
}

case "${1:-}" in
  preflight)
    : "${AWS_REGION:?}" "${MAX_RUN_USD:?}" "${GPU_TYPE:?}" "${NODE_TYPE:?}" "${GPU_DISK_GIB:?}" "${NODE_DISK_GIB:?}"
    arn="$(aws sts get-caller-identity --query Arn --output text)"
    role="${arn#*:assumed-role/}"; role="${role%%/*}"
    say "assumed $role through GitHub's OIDC token"
    # The subject GitHub writes into this environment's token, in its
    # immutable form, which the role's trust must name.
    subject="repo:${GITHUB_REPOSITORY_OWNER:?}@${GITHUB_REPOSITORY_OWNER_ID:?}/${GITHUB_REPOSITORY#*/}@${GITHUB_REPOSITORY_ID:?}:environment:aws-validation"
    aws iam get-role --role-name "$role" --query Role.AssumeRolePolicyDocument --output json | python3 -I -c '
import json, sys
doc, mine = json.load(sys.stdin), sys.argv[1]
subs = []
for s in doc["Statement"]:
    for cond in s.get("Condition", {}).values():
        for k, v in cond.items():
            if k.endswith(":sub"):
                subs += v if isinstance(v, list) else [v]
if mine not in subs:
    sys.exit("the role trusts %d subjects and not %s" % (len(subs), mine))
print("== its trust names %s, one of %d subjects" % (mine, len(subs)))' "$subject"

    # GPU and VT instances share one quota of vCPUs in the region, and the
    # flagship's weekly GPU run uses it too.
    quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --query Quota.Value --output text)"
    vcpus() { aws ec2 describe-instance-types --instance-types "$@" --query 'InstanceTypes[].[InstanceType, VCpuInfo.DefaultVCpus]' --output text; }
    need="$(vcpus "$GPU_TYPE" | awk '{print $2}')"
    running="$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running \
                 --query 'Reservations[].Instances[].InstanceType' --output text | tr '\t' '\n' | grep -E '^(g|vt)[0-9]' || true)"
    used=0
    if [ -n "$running" ]; then
      # shellcheck disable=SC2046 # one argument per running type
      used="$(vcpus $(sort -u <<<"$running") | awk 'NR==FNR {v[$1] = $2; next} {s += v[$1]} END {print s + 0}' - <(echo "$running"))"
    fi
    say "G and VT quota: ${quota%.*} vCPUs; running now: $used; this run needs $need ($GPU_TYPE)"
    if [ "$(( ${quota%.*} - used ))" -lt "$need" ]; then
      echo "the GPU quota is in use (${running//$'\n'/ }): another run, the flagship's on its day, holds it; nothing was created" >&2
      exit 1
    fi

    # What AWS refused to launch in the last day, and why: a zone out of g6
    # capacity shows here before a node group spends twenty minutes on it.
    # For the record, not a gate.
    aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
      --start-time "$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)" --max-items 200 --query 'Events[].CloudTrailEvent' --output json \
      | python3 -I -c '
import collections, json, sys
refused = collections.Counter()
for e in json.load(sys.stdin) or []:
    e = json.loads(e)
    if e.get("errorCode"):
        refused["%s: %s" % (e["errorCode"], (e.get("errorMessage") or "")[:160])] += 1
for what, n in refused.most_common(5):
    print("== launches refused in the last 24 h: %d x %s" % (n, what))
if not refused:
    print("== no launch refused in the last 24 h")' || say "CloudTrail could not be read"

    # This project's reservations, any state: one still active is residue
    # that bills like a running GPU.
    aws ec2 describe-capacity-reservations --filters "Name=tag:$TAG/project,Values=$PROJECT" \
      --query 'CapacityReservations[].[CapacityReservationId, AvailabilityZone, State, CreateDate, Tags[?Key==`'"$TAG"'/cluster`] | [0].Value]' --output text \
      | while read -r id zone state created owner; do say "reservation $id ($owner), $zone: $state, made $created"; done
    # And its instances in any state but terminated: one a teardown missed
    # bills by the hour, or for its disk while stopped.
    aws ec2 describe-instances --filters "Name=tag:$TAG/project,Values=$PROJECT" Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
      --query 'Reservations[].Instances[].[InstanceId, InstanceType, State.Name, LaunchTime, Tags[?Key==`'"$TAG"'/cluster`] | [0].Value]' --output text \
      | while read -r id itype state launched owner; do say "instance $id ($owner), $itype: $state, launched $launched"; done
    held="$(aws ec2 describe-capacity-reservations --filters "Name=tag:$TAG/project,Values=$PROJECT" Name=state,Values=active,pending \
              --query 'CapacityReservations[].CapacityReservationId' --output text)"
    if [ -n "$held" ]; then
      echo "a reservation of this project is still held ($held): it bills like a running $GPU_TYPE; nothing was created" >&2
      exit 1
    fi

    gpu_usd="$(price "$GPU_TYPE")"; node_usd="$(price "$NODE_TYPE")"
    # The most the run can cost: every hourly price for as long as the two
    # billed jobs' timeouts allow, read from the workflow itself.
    python3 -I - "$ROOT/.github/workflows/gpu.yml" "$gpu_usd" "$node_usd" "$GPU_DISK_GIB" "$NODE_DISK_GIB" "$MAX_RUN_USD" \
      "$EKS_USD_PER_HOUR" "$IPV4_USD_PER_HOUR" "$GP3_USD_PER_GB_MONTH" "${GITHUB_OUTPUT:-/dev/null}" "$GPU_TYPE" "$NODE_TYPE" <<'PY'
import re, sys
wf, gpu, node, gpu_disk, node_disk, cap, eks, ipv4, gp3, out, gpu_type, node_type = sys.argv[1:]
gpu, node, cap, eks, ipv4, gp3 = map(float, (gpu, node, cap, eks, ipv4, gp3))
text = open(wf).read()
def timeout(job):
    m = re.search(r"^  %s:\n(?:    .*\n|\s*\n)*?    timeout-minutes: (\d+)" % job, text, re.M)
    if not m:
        sys.exit("gpu.yml: no timeout-minutes for job %s" % job)
    return int(m.group(1))
minutes = timeout("up") + timeout("down")
hourly = eks + gpu + node + 2 * ipv4 + (int(gpu_disk) + int(node_disk)) * gp3 / 730
worst = hourly * minutes / 60
print("== on-demand an hour, from the AWS price list: %s $%.4f, %s $%.4f; with the control plane, two addresses and the disks $%.4f"
      % (gpu_type, gpu, node_type, node, hourly))
print("== the most this run can cost: %d minutes of jobs at $%.4f an hour, $%.2f, against a cap of $%.2f" % (minutes, hourly, worst, cap))
with open(out, "a") as f:
    f.write("gpu_usd=%s\nnode_usd=%s\nworst_usd=%.2f\n" % (gpu, node, worst))
if worst > cap:
    sys.exit("the run could cost $%.2f, more than $%.2f: shorten a timeout or raise the cap" % (worst, cap))
PY
    ;;

  sweep)
    : "${TF_STATE_BUCKET:?}" "${AWS_REGION:?}"
    # Runs of this workflow never overlap (concurrency gpu-run), so any other
    # run's state that still holds resources is what that run failed to
    # destroy, and any lock on it is one a stopped Terraform left.
    swept=0
    # shellcheck disable=SC2016  # the backticks are JMESPath's, not the shell's
    for key in $(aws s3api list-objects-v2 --bucket "$TF_STATE_BUCKET" --prefix "$PREFIX/" \
                   --query 'Contents[?ends_with(Key, `.tfstate`)].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true); do
      run="$(basename "$key" .tfstate)"
      [ "$run" = "${RUN_ID:-}" ] && continue
      left="$(aws s3 cp "s3://$TF_STATE_BUCKET/$key" - | python3 -I -c 'import json,sys; print(sum(len(r.get("instances", [])) for r in json.load(sys.stdin).get("resources", []) if r.get("mode") == "managed"))')"
      [ "$left" = 0 ] && continue
      say "run $run: $left resources left: destroying"
      work="$(mktemp -d)"
      aws s3 cp --quiet "s3://$TF_STATE_BUCKET/$PREFIX/$run.tfvars.json" "$work/run.tfvars.json"
      mkdir -p "$work/tf" && cp -r "$ROOT/eks/." "$work/tf/"
      rm -rf "$work/tf/.terraform" "$work/tf/tests"
      printf 'terraform {\n  backend "s3" {}\n}\n' >"$work/tf/ci_backend.tf"
      unlock "$key"
      terraform -chdir="$work/tf" init -input=false -lockfile=readonly -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=$key" -backend-config="region=$AWS_REGION" -backend-config="use_lockfile=true" >/dev/null
      destroy() { terraform -chdir="$work/tf" destroy -input=false -auto-approve -var-file="$work/run.tfvars.json" -var 'operator_cidrs=["198.51.100.1/32"]' >/dev/null; }
      # A node group the state never held keeps the cluster from going.
      destroy || { CLUSTER="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["cluster_name"])' "$work/run.tfvars.json")" "$0" stop; destroy; }
      say "run $run: destroyed"; swept=$((swept + 1))
    done
    say "swept $swept earlier run(s)"
    ;;

  unlock)
    : "${TF_STATE_BUCKET:?}" "${RUN_ID:?}"
    unlock "$PREFIX/$RUN_ID.tfstate"
    ;;

  reserve)
    : "${TF_STATE_BUCKET:?}" "${RUN_ID:?}" "${CLUSTER:?}" "${VARS:?}" "${GPU_TYPE:?}"
    # Asked of EC2 directly, then imported, so Terraform destroys it with
    # the rest. EC2 answers a zone with no capacity in one of two ways: it
    # refuses the request (InsufficientInstanceCapacity), or it takes it and
    # the reservation turns to failed, which bills nothing. Run 41075374482
    # asked through Terraform, which had no answer after five minutes; the
    # reservation it left in us-east-1a had failed. Each zone gets two
    # minutes for an answer and two for the reservation to settle.
    # The zones eks/network.tf will use, asked of EC2 before anything is
    # made: available, offering both instance types, and not use1-az3. The
    # GPU reservation's precondition refuses a zone Terraform would not use.
    zones="$(python3 -I -c '
import json, sys
zones, gpu, node = (json.loads(a) for a in sys.argv[1:4])
print(" ".join(sorted(name for name, zid in zones if zid != "use1-az3" and name in gpu and name in node)))' \
      "$(aws ec2 describe-availability-zones --filters Name=opt-in-status,Values=opt-in-not-required Name=state,Values=available \
           --query 'AvailabilityZones[].[ZoneName, ZoneId]' --output json)" \
      "$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters "Name=instance-type,Values=$GPU_TYPE" \
           --query 'InstanceTypeOfferings[].Location' --output json)" \
      "$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters "Name=instance-type,Values=${NODE_TYPE:?}" \
           --query 'InstanceTypeOfferings[].Location' --output json)")"
    ends="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["gpu_reservation_ends"])' "$VARS")"
    tags="$(python3 -I -c 'import json,sys; t, p, c, r = sys.argv[1:]; print(json.dumps([{"ResourceType": "capacity-reservation", "Tags": [
      {"Key": t + "/project", "Value": p}, {"Key": t + "/cluster", "Value": c}, {"Key": "run-id", "Value": r},
      {"Key": "managed-by", "Value": "terraform"}, {"Key": "Name", "Value": c + "-gpu"}]}]))' "$TAG" "$PROJECT" "$CLUSTER" "$RUN_ID")"
    # held <zone>: this run's reservations in the zone that are not settled
    # or still bill (pending, active), to cancel before the next zone.
    held() {
      aws ec2 describe-capacity-reservations --filters "Name=tag:$TAG/cluster,Values=$CLUSTER" "Name=availability-zone,Values=$1" \
        Name=state,Values=pending,active --query 'CapacityReservations[].CapacityReservationId' --output text
    }
    refused=""
    for z in $zones; do
      out="$(AWS_MAX_ATTEMPTS=2 timeout 2m aws ec2 create-capacity-reservation --instance-type "$GPU_TYPE" --instance-platform Linux/UNIX \
               --availability-zone "$z" --instance-count 1 --instance-match-criteria targeted --end-date-type limited --end-date "$ends" \
               --tag-specifications "$tags" --query CapacityReservation.CapacityReservationId --output text 2>&1)" && rc=0 || rc=$?
      state=""
      if [ "$rc" -eq 0 ]; then
        for _ in $(seq 1 24); do
          state="$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "$out" --query 'CapacityReservations[0].State' --output text)"
          [ "$state" = pending ] || break
          sleep 5
        done
        if [ "$state" = active ]; then
          python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])); v["gpu_zone"]=sys.argv[2]; json.dump(v, open(sys.argv[1], "w"), indent=1)' "$VARS" "$z"
          aws s3 cp --quiet "$VARS" "s3://$TF_STATE_BUCKET/$PREFIX/$RUN_ID.tfvars.json"
          terraform -chdir="$ROOT/eks" import -input=false -no-color -var-file="$VARS" 'aws_ec2_capacity_reservation.gpu[0]' "$out" >/dev/null
          say "one $GPU_TYPE reserved in $z ($out)${refused:+, after no capacity in$refused}"
          exit 0
        fi
        say "$z: EC2 took the request and the reservation is $state"
      elif grep -q InsufficientInstanceCapacity <<<"$out"; then
        say "$z: no $GPU_TYPE capacity"
      elif [ "$rc" -eq 124 ]; then
        say "$z: no answer in two minutes"
      else
        printf '%s\n' "$out" >&2
        exit 1
      fi
      for id in $(held "$z"); do aws ec2 cancel-capacity-reservation --capacity-reservation-id "$id" >/dev/null && say "$z: cancelled $id"; done
      refused="$refused $z"
    done
    echo "no zone of the run had a $GPU_TYPE to reserve ($zones): no GPU was made, and the run stops here" >&2
    exit 1
    ;;

  gpu)
    kubectl wait nodes -l "$GPU_LABEL" --for=condition=Ready --timeout=600s >/dev/null
    kubectl apply -f "$ROOT/deploy/gpu/device-plugin.yaml" >/dev/null
    kubectl -n kube-system rollout status ds/nvidia-device-plugin --timeout=300s >/dev/null
    offered=""
    for _ in $(seq 1 60); do
      offered="$(kubectl get nodes -l "$GPU_LABEL" -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')"
      [ "$offered" = 4 ] && break
      sleep 5
    done
    [ "$offered" = 4 ] || { echo "the GPU node offers '${offered:-nothing}' nvidia.com/gpu, not 4" >&2; exit 1; }
    say "the GPU node offers its one L4 to the scheduler as 4 nvidia.com/gpu, by time-slicing"
    ;;

  check)
    : "${MODEL:?}" "${RESULTS:?}"
    mkdir -p "$RESULTS"
    nodes="$(kubectl get nodes -l "$GPU_LABEL" -o jsonpath='{.items[*].metadata.name}')"
    [ "$(wc -w <<<"$nodes")" -eq 1 ] || { echo "expected one GPU node, found: ${nodes:-none}" >&2; exit 1; }
    fail=0
    rows=""
    for pod in $(kubectl get pods -l app=model-server -o jsonpath='{.items[*].metadata.name}'); do
      on="$(kubectl get pod "$pod" -o jsonpath='{.spec.nodeName}')"
      [ "$on" = "$nodes" ] || { echo "FAIL: $pod runs on $on, not the GPU node" >&2; fail=1; }
      gpu="$(kubectl exec "$pod" -c vllm -- nvidia-smi --query-gpu=uuid,name,memory.used,memory.total,driver_version --format=csv,noheader,nounits)"
      weights="$(kubectl logs "$pod" -c weights)"
      if grep -q '^BAD' <<<"$weights" || [ "$(grep -c '^ok ' <<<"$weights")" -ne "$(kubectl get configmap model-files -o jsonpath='{.data.sha256}' | grep -c .)" ]; then
        echo "FAIL: $pod: its weights were not all checked against their digests" >&2; fail=1
      fi
      served="$(kubectl get --raw "/api/v1/namespaces/default/pods/$pod:8000/proxy/v1/models" | python3 -I -c 'import json,sys; print(" ".join(m["id"] for m in json.load(sys.stdin)["data"]))')"
      [ "$served" = "$MODEL" ] || { echo "FAIL: $pod serves '$served', not $MODEL" >&2; fail=1; }
      rows="$rows$pod, $gpu"$'\n'
    done
    python3 -I - "$rows" "$RESULTS/gpu.json" "$MODEL" <<'PY' || fail=1
import json, sys
rows = [[c.strip() for c in r.split(",")] for r in sys.argv[1].splitlines() if r.strip()]
bad = 0
if len(rows) != 4:
    print("FAIL: %d model servers, not four" % len(rows)); bad = 1
uuids = {r[1] for r in rows}
if len(uuids) != 1:
    print("FAIL: the model servers are on %d GPUs, not one shared" % len(uuids)); bad = 1
pod, uuid, name, used, total, driver = rows[0]
print("OK: %d model servers serving %s, all on one %s (driver %s), which holds %s of %s MiB"
      % (len(rows), sys.argv[3], name, driver, used, total))
json.dump({"gpu": name, "driver": driver, "memory_used_mib": int(used), "memory_total_mib": int(total),
           "replicas": len(rows), "model": sys.argv[3]}, open(sys.argv[2], "w"))
sys.exit(bad)
PY
    [ "$fail" -eq 0 ] || exit 1
    ;;

  tokens)
    : "${RESULTS:?}" "${GPU_USD:?}" "${NODE_USD:?}" "${GPU_TYPE:?}"
    python3 -I - "$RESULTS" "$GPU_USD" "$NODE_USD" "$EKS_USD_PER_HOUR" "$GPU_TYPE" <<'PY'
import glob, json, os, sys
d, gpu, node, eks, gpu_type = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
cluster = gpu + node + eks
out = {"gpu_usd_per_hour": gpu, "cluster_usd_per_hour": round(cluster, 4), "routes": {}}
print("| Route | Runs | Requests | Output tokens | Prompt tokens | In cache | Wall time | Output tokens/s "
      "| A million output tokens, the %s alone | With the CPU node and the control plane |" % gpu_type)
print("|---|---|---|---|---|---|---|---|---|---|")
for route, name in (("roundrobin", "Round-robin Service"), ("router", "llm-d router")):
    runs = [json.load(open(p)) for p in sorted(glob.glob(os.path.join(d, route + "-*.json")))]
    if not runs or any(r.get("output_tokens") is None for r in runs):
        sys.exit("%s: no runs with token counts in %s" % (route, d))
    wall = sum(r["wall_s"] for r in runs)
    o = sum(r["output_tokens"] for r in runs)
    i = sum(r["prompt_tokens"] for r in runs)
    hits = [r["cache_hit_rate"] for r in runs]
    rate = o / wall
    per_m = lambda usd: usd / (rate * 3600) * 1e6
    out["routes"][route] = {"runs": len(runs), "requests": sum(r["requests"] for r in runs), "output_tokens": o,
                            "prompt_tokens": i, "wall_s": round(wall, 2), "output_tokens_per_s": round(rate, 1),
                            "usd_per_million_output_tokens_gpu": round(per_m(gpu), 3),
                            "usd_per_million_output_tokens_cluster": round(per_m(cluster), 3),
                            "cache_hit_rate": hits}
    print("| %s | %d | %d | %d | %d | %s | %.1f s | %.1f | $%.2f | $%.2f |" % (
        name, len(runs), out["routes"][route]["requests"], o, i, " / ".join("%.0f%%" % (100 * h) for h in hits),
        wall, rate, per_m(gpu), per_m(cluster)))
json.dump(out, open(os.path.join(d, "cost-per-token.json"), "w"), indent=1)
PY
    ;;

  diagnose)
    : "${CLUSTER:?}"
    # AWS's side first: a node group that never became active says why in
    # its health and in its Auto Scaling group's launch attempts (run
    # 41067783938's GPU group spent 19 minutes creating with nothing here
    # to say why).
    if aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text 2>/dev/null; then
      aws eks update-kubeconfig --name "$CLUSTER" >/dev/null 2>&1 || true
      for g in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --query nodegroups --output text 2>/dev/null); do
        aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$g" \
          --query 'nodegroup.[nodegroupName, status, health.issues]' --output json || true
        for asg in $(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$g" \
                       --query 'nodegroup.resources.autoScalingGroups[].name' --output text 2>/dev/null); do
          aws autoscaling describe-scaling-activities --auto-scaling-group-name "$asg" --max-items 6 \
            --query 'Activities[].[StartTime, StatusCode, StatusMessage]' --output text || true
        done
      done
    fi
    aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
      --start-time "$(date -u -d '-90 minutes' +%Y-%m-%dT%H:%M:%SZ)" --max-items 100 --query 'Events[].CloudTrailEvent' --output json 2>/dev/null \
      | python3 -I -c '
import json, sys
for e in json.load(sys.stdin) or []:
    e = json.loads(e)
    if e.get("errorCode"):
        print(e["eventTime"], e["errorCode"], (e.get("errorMessage") or "")[:200])' || true
    kubectl get nodes -o wide -L "$TAG/accelerator" || true
    kubectl get pods -A -o wide || true
    kubectl get events -A --sort-by=.lastTimestamp | tail -40 || true
    kubectl -n kube-system logs ds/nvidia-device-plugin --tail=30 || true
    for pod in $(kubectl get pods -l app=model-server -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      echo "--- $pod"
      kubectl get pod "$pod" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}: {.state}{"\n"}{end}{range .status.containerStatuses[*]}{.name}: {.state} last {.lastState}{"\n"}{end}' || true
      kubectl logs "$pod" -c weights --tail=12 || true
      kubectl logs "$pod" -c vllm --tail=60 || true
    done
    kubectl logs deploy/router-epp --tail=40 --all-containers || true
    ;;

  stop)
    : "${CLUSTER:?}" "${AWS_REGION:?}"
    groups="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query nodegroups --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true)"
    for g in $groups; do aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$g" >/dev/null && say "deleting node group $g"; done
    for g in $groups; do aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$g" || true; done
    ids="$(aws ec2 describe-instances --filters "Name=tag:$TAG/cluster,Values=$CLUSTER" Name=instance-state-name,Values=pending,running,stopping,stopped \
             --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' ' ')"
    if [ -n "${ids// /}" ]; then
      # shellcheck disable=SC2086 # one argument per instance
      aws ec2 terminate-instances --instance-ids $ids >/dev/null && say "terminated $ids"
    fi
    for cr in $(aws ec2 describe-capacity-reservations --filters "Name=tag:$TAG/cluster,Values=$CLUSTER" Name=state,Values=active,pending \
                  --query 'CapacityReservations[].CapacityReservationId' --output text); do
      aws ec2 cancel-capacity-reservation --capacity-reservation-id "$cr" >/dev/null && say "cancelled reservation $cr"
    done
    say "no node of $CLUSTER is left running and no reservation of it held"
    ;;

  residue)
    : "${CLUSTER:?}" "${AWS_REGION:?}"
    # exists <arn>: the tagging API keeps a deleted resource's tags for a
    # while; a resource it lists is asked about directly before it counts.
    exists() {
      local id="${1##*/}"
      case "$1" in
        *:vpc/*) aws ec2 describe-vpcs --vpc-ids "$id" >/dev/null 2>&1 ;;
        *:subnet/*) aws ec2 describe-subnets --subnet-ids "$id" >/dev/null 2>&1 ;;
        *:route-table/*) aws ec2 describe-route-tables --route-table-ids "$id" >/dev/null 2>&1 ;;
        *:internet-gateway/*) aws ec2 describe-internet-gateways --internet-gateway-ids "$id" >/dev/null 2>&1 ;;
        *:security-group/*) aws ec2 describe-security-groups --group-ids "$id" >/dev/null 2>&1 ;;
        *:launch-template/*) aws ec2 describe-launch-templates --launch-template-ids "$id" >/dev/null 2>&1 ;;
        *:volume/*) aws ec2 describe-volumes --volume-ids "$id" >/dev/null 2>&1 ;;
        *:capacity-reservation/*) case "$(aws ec2 describe-capacity-reservations --capacity-reservation-ids "$id" --query 'CapacityReservations[0].State' --output text 2>/dev/null)" in
                                    active|pending) true ;; *) false ;; esac ;;
        *:instance/*) [ "$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)" != terminated ] \
                        && aws ec2 describe-instances --instance-ids "$id" >/dev/null 2>&1 ;;
        *) true ;;
      esac
    }
    really="" elsewhere="" gone=0
    # shellcheck disable=SC2016 # the backticks are JMESPath's, not the shell's
    while read -r arn owner; do
      [ -n "$arn" ] || continue
      if ! exists "$arn"; then gone=$((gone + 1)); continue; fi
      if [ "$owner" = "$CLUSTER" ]; then really="$really $arn"; else elsewhere="$elsewhere $arn ($owner)"; fi
    done < <(aws resourcegroupstaggingapi get-resources --tag-filters "Key=$TAG/project,Values=$PROJECT" "Key=$TAG/cluster" \
               --query "ResourceTagMappingList[].[ResourceARN, Tags[?Key=='$TAG/cluster'] | [0].Value]" --output text || true)
    roles="$(aws iam list-roles --query "Roles[?starts_with(RoleName, 'reference-platform-inference-')].RoleName" --output text | tr '\t' '\n' | grep -v '^$' || true)"
    cluster="$(aws eks list-clusters --query "clusters[?starts_with(@, 'reference-platform-inference-')]" --output text | tr '\t' ' ')"
    # A reservation bills like the instance; asked for by state as well as
    # through the tagging API.
    held="$(aws ec2 describe-capacity-reservations --filters "Name=tag:$TAG/project,Values=$PROJECT" Name=state,Values=active,pending \
              --query 'CapacityReservations[].CapacityReservationId' --output text | tr '\t' ' ')"
    [ "$gone" -gt 0 ] && say "the tagging API still lists $gone resource(s) that no longer exist"
    if [ -z "${really// /}" ] && [ -z "${elsewhere// /}" ] && [ -z "$roles" ] && [ -z "${cluster// /}" ] && [ -z "${held// /}" ]; then
      say "nothing left of $CLUSTER, and nothing of any earlier run"; exit 0
    fi
    echo "left behind: clusters '${cluster:-none}'; reservations '${held:-none}'; roles: ${roles//$'\n'/ }; this run's tagged:${really:- none}; earlier runs':${elsewhere:- none}" >&2
    exit 1
    ;;

  cost)
    : "${CLUSTER:?}" "${STARTED:?}" "${GPU_USD:?}" "${NODE_USD:?}" "${GPU_TYPE:?}" "${NODE_TYPE:?}" "${GPU_DISK_GIB:?}" "${NODE_DISK_GIB:?}" "${MAX_RUN_USD:?}"
    instances="$(aws ec2 describe-instances --filters "Name=tag:$TAG/cluster,Values=$CLUSTER" \
      --query 'Reservations[].Instances[].[InstanceType, LaunchTime, State.Name, StateTransitionReason]' --output json)"
    reserved="$(aws ec2 describe-capacity-reservations --filters "Name=tag:$TAG/cluster,Values=$CLUSTER" \
      --query 'CapacityReservations[].[InstanceType, CreateDate, State]' --output json)"
    python3 -I - "$instances" "$reserved" "$STARTED" "$(date +%s)" "$GPU_TYPE" "$GPU_USD" "$NODE_TYPE" "$NODE_USD" "$GPU_DISK_GIB" "$NODE_DISK_GIB" \
      "$EKS_USD_PER_HOUR" "$IPV4_USD_PER_HOUR" "$GP3_USD_PER_GB_MONTH" "$MAX_RUN_USD" "${APPLIED:-}" <<'PY'
import datetime as dt, json, re, sys
instances, reserved = json.loads(sys.argv[1]), json.loads(sys.argv[2])
started, now = int(sys.argv[3]), int(sys.argv[4])
gpu_type, gpu, node_type, node = sys.argv[5], float(sys.argv[6]), sys.argv[7], float(sys.argv[8])
disk = {gpu_type: int(sys.argv[9]), node_type: int(sys.argv[10])}
price = {gpu_type: gpu, node_type: node}
eks, ipv4, gp3, cap = map(float, sys.argv[11:15])
def epoch(s):
    return int(dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
# The control plane from the apply, which a run that found no L4 never
# reached, to the end of the destroy.
applied = int(sys.argv[15]) if sys.argv[15] else now
rows = [("EKS control plane, from the apply to the end of the destroy", eks, (now - applied) / 3600)]
# A reservation bills as its instance would, from its start to its end,
# with the instance inside it or not, and the instance it holds bills
# nothing more. Priced to the end of the destroy, which ends it.
in_reservation = set()
for itype, created, state in reserved:
    h = (now - epoch(created)) / 3600
    if state == "failed":
        # EC2 could not fill it, and bills nothing for it.
        rows.append(("one %s asked for, which EC2 could not reserve (failed)" % itype, 0.0, h))
        continue
    rows.append(("one %s reserved, %s, %.2f h, its node inside it" % (itype, state, h), price[itype], h))
    in_reservation.add(itype)
for itype, launched, state, reason in instances:
    # EC2 bills an instance by the second from its launch to its termination,
    # which it records as "User initiated (YYYY-MM-DD HH:MM:SS GMT)".
    m = re.search(r"\((\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) GMT\)", reason or "")
    end = epoch(m.group(1).replace(" ", "T") + "Z") if state == "terminated" and m else now
    h = max(end - epoch(launched), 60) / 3600
    if itype in in_reservation:
        rows.append(("one %s, %s, %.2f h, billed through its reservation" % (itype, state, h), 0.0, h))
    else:
        rows.append(("one %s, %s, %.2f h" % (itype, state, h), price[itype], h))
    rows.append(("its public IPv4 address and %d GiB gp3" % disk[itype], ipv4 + disk[itype] * gp3 / 730, h))
total = sum(r * h for _, r, h in rows)
print("| What | Per hour | This run |\n|---|---|---|")
for what, rate, h in rows:
    print("| %s | $%.4f | $%.2f |" % (what, rate, rate * h))
print("| **Total, %.2f h, at on-demand prices** | | **about $%.2f** |" % ((now - started) / 3600, total))
if total > cap:
    sys.exit("the run cost about $%.2f, more than the $%.2f it is allowed" % (total, cap))
PY
    ;;

  *) echo "usage: eks.sh <preflight|sweep|unlock|reserve|gpu|check|tokens|diagnose|stop|residue|cost>" >&2; exit 2 ;;
esac
