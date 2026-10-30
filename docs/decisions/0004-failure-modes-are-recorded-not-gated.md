# 4. What a failing replica does to each route is recorded, not gated

Accepted, 2026-10-30.

## Context

The comparison in ADR 3 runs on four healthy replicas. A router that picks replicas by their load also decides where requests go when one of them fails, and how it fails matters. A replica that cannot be reached holds on to every request it is given, so it looks busy. A replica that answers every request with an immediate error never holds one, so it looks idle. A router that sends work to the least loaded replica can avoid the first and send ever more traffic to the second.

Readiness is the way out. Both pools, the `InferencePool` and the Service, follow the pods' readiness, and in these runs nothing else took a replica out: a server whose health endpoint still answered kept receiving traffic for as long as that stayed true.

## Decision

- **Three ways one replica of four fails**, each through the router and through the round-robin Service:
  - *sick*: every completion answered at once with an error while `/health` stays fine (the simulator's failure injection, `deploy/sick-replica.yaml`), at 10, 50 and 150 requests a second;
  - *unreachable*: packets to it dropped for six seconds on the kind node while it stays Ready;
  - *crashed*: its server process killed with SIGKILL, and restarted by the kubelet.
- **An open-loop probe** (`loadgen/probe.py`): new single-turn requests on a fixed schedule, whatever happened to the ones before. The conversation load is closed-loop, and a closed-loop load sends its next request sooner when the last one fails fast, so it would pile requests onto the failing replica that a real crowd of users would not.
- **Recorded, not gated.** `tests/failure-modes.sh` fails only when a scenario did not happen as designed, and round-robin is the witness, because its behaviour is known: about a quarter of its requests fail against the sick replica, some of its requests stall while one is unreachable, and a crashed replica restarts. What the router does is reported, whatever it is. Each witness check is shown its break in `tests/failure-plants.tsv`.
- **Two router builds.** The release, as the comparison runs it, and llm-d's main build with its `endpoint-health-filter` first in the profile (`deploy/router-health-filter.yaml`). That filter ejects a replica after consecutive 502 or 503 responses; it merged a week after v1.0.0 and no release carries it, so the main build is pinned by digest in `images.lock`. When a release carries it, that release replaces the main build.
- **Weekly**, and on any push that changes the scenarios, the model servers or the router's values. A run takes minutes.

## Consequences

- A router release that changes how it treats a failing replica changes the weekly numbers, and nothing turns red: reading them is a person's job. The README carries the numbers of one run, dated.
- The sick replica fails every request. Partial failure is not measured, nor slow failure.
- One node, simulated replicas. On a real cluster a lost node is noticed only after the node controller's grace period, so the unreachable case lasts longer than six seconds there, and a vLLM whose engine has died stays in the pool until its health endpoint says so and the probe has failed `failureThreshold` times.
