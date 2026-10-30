# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The comparison on a GPU** (`.github/workflows/gpu.yml`, ADR 5): the same router, values, load, round-robin Service and thresholds as the kind run, on Amazon EKS, in front of four vLLM v0.32.0 replicas of Qwen2.5-1.5B-Instruct that share one NVIDIA L4 (g6.xlarge) by the device plugin's time-slicing, and what a million output tokens cost on each route at the on-demand price. Weekly behind `AWS_VALIDATION_ENABLED`, and by hand.
- **A preflight before anything is billed**: the creation role's trust, the account's GPU quota against what already runs, the prices from the AWS Price List API, refused launches from CloudTrail, any reservation or instance of the project still alive, and the most the run could cost if every billed job ran to its timeout, refused above $1.50 (`scripts/eks.sh`).
- **Capacity first**: one L4 reserved (a targeted On-Demand Capacity Reservation that ends by itself) before anything else is made, tried in every zone that offers both instance types, round after round for fifteen minutes; with none, the run makes nothing and stops. The cluster and both node groups come from one apply, the GPU node into the reservation.
- **A teardown that holds when a run breaks**: each apply interrupted before its step's timeout, a stale state lock removed, node groups deleted through the CLI when a destroy fails, the reservation cancelled, a residue check over this run and every earlier one, a sweep of earlier runs' states and orphans, and the cost from each instance's launch and termination and the reservation's start, failed above $1.50.
- **An A10G when no zone has an L4**: the reservation's rounds ask every zone for a g6.xlarge first and then for a g5.xlarge, and the run names the card it ran on, `NVIDIA L4 (g6.xlarge)` or `NVIDIA A10G (g5.xlarge), fallback: no L4 in any zone`, from `nvidia-smi` and the node's instance type, never mixing the two in one row. `tests/gpu-card.sh` and its three plants (`tests/gpu-card-plants.tsv`) run on every push.
- **The model's weights pinned file by file**: a commit of its Hugging Face repository and the sha256 of every file the server reads, checked in each pod before vLLM starts (`deploy/gpu/model-server.yaml`).
- **The GPU run's Terraform** (`eks/`), checked on a plan against a mocked AWS provider on every push, its tests shown five breaks (`eks/tests/plants.tsv`).
- **ADR 5**: the same comparison on one L4, shared by four vLLM replicas.

### Changed

- `scripts/run-load.sh` adds the prompt and output tokens the model servers counted, and reads every metric by its exact name (vLLM also exports `vllm:prompt_tokens_cached_total`).
- `scripts/up.sh` takes `USE_KIND=0` for a cluster it did not make, `MODEL_SERVERS` and `MODEL_SERVER_WORKLOAD` for other model servers, and `ROLLOUT_TIMEOUT`; it restarts the model servers only when they existed before, since new ones have served nothing.
- `tests/e2e.sh` takes `MODEL`, the model the servers serve.

### Fixed

- **A test piped into `tee` now fails its step.** GitHub runs a step with no `shell` as `bash -e`, without `pipefail`, so `./tests/e2e.sh | tee -a "$GITHUB_STEP_SUMMARY"` took `tee`'s exit status: a failed comparison, a failed scenario or a missed plant would have left the job green. Every workflow now runs its steps as `bash` with `pipefail`. No run on main had hidden a failure: none of the last eight E2E and Failure modes runs on main printed a FAIL, MISSED or STALE line.

## [1.1.0] - 2026-10-30

### Added

- **What a failing replica does to each route**: `tests/failure-modes.sh` fails one replica of four three ways (a sick replica that answers every completion with an instant error while its health endpoint is fine, an unreachable one that stays Ready, a crashed one) and sends an open-loop probe through the router and through round-robin. It records the numbers and fails only when a scenario did not happen as designed, which round-robin witnesses; its checks are shown their breaks in `tests/failure-plants.tsv`. Weekly, in its own workflow.
- **The open-loop probe** `loadgen/probe.py`: new single-turn requests on a fixed schedule, so a fast failure cannot speed up the arrivals.
- **The router with llm-d's endpoint-health-filter**, from llm-d's main build pinned by digest (`deploy/router-health-filter.yaml`, `EPP_MAIN_IMAGE` in `images.lock`), beside the release in the failure scenarios: no release carries the filter yet. `scripts/up.sh` takes `ROUTER_EXTRA_VALUES` for a values file layered over the router's.
- **ADR 4**: failure modes are recorded, not gated.
- `tests/plant-violations.py` takes `PLANTS` for a table other than `tests/plants.tsv`.

## [1.0.0] - 2026-10-30

### Added

- **The comparison**: the llm-d router (llm-d-router-standalone v1.0.0, optimized-baseline plugins) against a plain round-robin Service, in front of the same four simulated model servers (llm-d-inference-sim v1.0.0, prefix KV cache on), under the same multi-turn load, on kind, every push and every day.
- **The load generator**: conversations that resend their history, streamed, timed at the first content token; a stream cut before `[DONE]` is a failure.
- **The checks** in `tests/e2e.sh`, each shown the break it exists for in `tests/plants.tsv`.
- **What runs is what is pinned**: the test fails if any image in the cluster is not one `images.lock` names by digest, the Envoy the router chart brings by default included, which `deploy/router-values.yaml` pins.
- **Three decision records**: the simulator before the GPU, the plain Service as baseline, the load and how it is measured.

[1.1.0]: https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/releases/tag/v1.1.0
[1.0.0]: https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/releases/tag/v1.0.0
