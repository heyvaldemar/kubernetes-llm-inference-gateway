# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
