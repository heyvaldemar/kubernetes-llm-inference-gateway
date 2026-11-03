# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A live record of the e2e runs**, as kubernetes-postgres-recovery and cypress-cloud-triage-agent keep: `.github/workflows/status.yml` runs `scripts/status.py` after every E2E run on main and daily, and rewrites the one-commit branch `status` with `status.json` (green days of the last 30, the streak, the runs, and the latest run's checks and measurements) and the shields.io badge files the README's second row of badges reads. Only the kind e2e feeds it; the failure-modes and GPU runs do not.
- `tests/e2e.sh` writes what it printed to `E2E_RESULTS` when that is set: every `OK` and `FAIL` line a check, and two `MEASURED` lines, the router's time to first token after the first turn as a share of round-robin's and both routes' prefix cache hits, low to high over the rounds. The e2e job sets it on the comparison step only, so the plants do not overwrite it, adds the plants' verdict as one more check, and uploads it as `e2e-results`. Each round now also prints an `OK` line when every request was answered; before, only a failure printed one.
- **`AGENTS.md`**, the rules an agent works under here, read from the code and the decision records: which check backs each README claim, which run writes which numbers, the gates and why they sit where they do, where each pin lives, how a change is proved on a branch, that the GPU run is billed and started only by its schedule or the maintainer, releases, and what is never done. `CLAUDE.md` imports it.

### Changed

- **README**: "What it does not do" counts the five GPU runs that served the model, by card and outcome, and says no weekly GPU result is claimed until a scheduled run passes (next 2026-11-08); it still said one run, on the A10G, with no L4 run passed. "What it costs" gives the 2026-11-01 runs' cost too.

## [1.3.0] - 2026-11-01

### Changed

- **The GPU run judges its time at the 90th percentile, at most 0.6 of round-robin's** (ADR 5, 2026-11-01); kind keeps the median at 0.6. The first scheduled run, 41298441298, got an L4 and failed only kind's median check, 0.61 and 0.67, with every request answered and 81% of prompt tokens in cache against 44% and 41%. On a GPU four replicas share, the router's median is the card's step (205 to 213 ms on the L4); the tail is where a miss lands. Working routers measured 0.21 to 0.45 at the 90th percentile, a router planted to pick at random 0.99 (41319020421, which failed both checks). An interim threshold of 0.8 on the median, set the same morning, sat 0.07 from both and was replaced before any scheduled run used it. The hit-rate check is unchanged. First live run under the rule: 41328394855, on the A10G fallback, 0.26 and 0.19.
- `tests/e2e.sh` takes `RATIO_PERCENTILE` (50 by default) and `JUDGE_ONLY=1`, which judges results already saved and runs nothing.

### Added

- **The GPU run's thresholds tested on every push**: `tests/gpu-judge.sh` replays four GPU runs' saved results (`tests/fixtures/gpu/`) through the judgement with the values it reads from `gpu.yml`; the three working routers must pass, the random-picking one must fail, on time alone too. Three plants (`tests/gpu-judge-plants.tsv`).
- **A planted break for the GPU run itself**: a dispatch with `plant: random-picker` layers `tests/gpu-plants/random-picker-values.yaml` over the router's values, kind's random-picker plant; run 41319020421 failed as it must.

## [1.2.0] - 2026-10-30

### Added

- **The comparison on a GPU** (`.github/workflows/gpu.yml`, ADR 5): the same router, values, load, round-robin Service and thresholds as the kind run, on Amazon EKS, in front of four vLLM v0.32.0 replicas of Qwen2.5-1.5B-Instruct that share one NVIDIA L4 (g6.xlarge) by the device plugin's time-slicing, and what a million output tokens cost on each route at the on-demand price. Weekly on Sunday behind `AWS_VALIDATION_ENABLED`, and by hand. First passed by hand on 2026-10-30, run 41089439304, on the A10G fallback (no L4 in any zone): the router's median time to first token after the first turn 0.50 and 0.42 of round-robin's, 81% of prompt tokens in cache against 42 to 44%, $0.84 a million output tokens against $1.23.
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

[1.3.0]: https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/releases/tag/v1.3.0
[1.2.0]: https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/releases/tag/v1.2.0
[1.1.0]: https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/releases/tag/v1.1.0
[1.0.0]: https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/releases/tag/v1.0.0
