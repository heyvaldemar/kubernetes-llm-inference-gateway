# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The comparison**: the llm-d router (llm-d-router-standalone v1.0.0, optimized-baseline plugins) against a plain round-robin Service, in front of the same four simulated model servers (llm-d-inference-sim v1.0.0, prefix KV cache on), under the same multi-turn load, on kind, every push and every day.
- **The load generator**: conversations that resend their history, streamed, timed at the first content token; a stream cut before `[DONE]` is a failure.
- **The checks** in `tests/e2e.sh`, each shown the break it exists for in `tests/plants.tsv`.
- **Three decision records**: the simulator before the GPU, the plain Service as baseline, the load and how it is measured.
