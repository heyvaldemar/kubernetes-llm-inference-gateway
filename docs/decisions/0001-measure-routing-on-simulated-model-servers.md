# 1. Measure routing on simulated model servers first, on a real GPU second

Accepted, 2026-10-30.

## Context

The claim this repository exists to test is narrow: for multi-turn traffic, routing each request to the model server that already holds its conversation's prefix in its KV cache answers sooner than spreading requests evenly. The llm-d router (llm-d 1.0, October 2026) does this through the Gateway API Inference Extension: an Envoy proxy asks an Endpoint Picker (EPP) over ext_proc which replica of an `InferencePool` gets each request.

Testing that claim on GPUs every day would cost money and bring noise the claim does not depend on: model load times, GPU contention, a real model's output length.

## Decision

The daily test runs on kind with `llm-d-inference-sim` v1.0.0 as the model server. The simulator speaks vLLM's OpenAI API and exports vLLM's Prometheus metrics, keeps a prefix KV cache per replica (`--enable-kvcache`), and charges prefill time only for the tokens that cache does not hold:

    prefill = prefill-overhead + (prompt tokens − cached tokens) × prefill-time-per-token

So the effect under test is present, and nothing else is: no randomness in latency, no GPU, no model download. Its tokenizer is the simulator's own (no `--render-url`), which needs no network; token counts are approximate, which does not matter for a comparison between two routes on the same tokenizer.

The baseline is the same four replicas behind a plain Kubernetes Service. Both routes get the same load generator, the same conversations (seeded), and caches emptied by a restart before each test.

The router is `llm-d-router-standalone` v1.0.0 with llm-d's optimized-baseline plugins: prefix-cache affinity, then the replica with the least prefill work queued. Its resource requests are cut from the chart's production defaults (8 CPU for the EPP) to fit one kind node; the scheduling logic is unchanged.

A weekly run on one NVIDIA L4 with vLLM and a small real model is the second step, in the AWS account the other reference architectures use: what the simulator shows as a ratio, the GPU shows in seconds and dollars per million tokens.

## Consequences

- The numbers measured on kind are about the routing, not about any model: a model with faster prefill per token gains less in absolute time from a cache hit, and a longer shared prefix gains more. The README says so next to the numbers.
- The thresholds in `tests/e2e.sh` (router TTFT at most 0.6 of round-robin's after the first turn; hit rate at least 20 points higher) sit well inside what is measured (about 0.35, and about 38 points), so a failure means the routing broke, not that a run was unlucky.
- A new simulator, router or chart release that changes the result shows up within a day, because the comparison runs every day on a fresh runner.
