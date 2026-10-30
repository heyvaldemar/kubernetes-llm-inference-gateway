# 3. A load that resends its history, measured where the user waits

Accepted, 2026-10-30.

## Context

A benchmark that sends independent single prompts shows no benefit from a prefix cache, because nothing repeats. A benchmark that reports only throughput hides what a user feels, which is the wait for the first token.

## Decision

- **The load is conversations.** Each of 32 sessions has a system prompt of its own (about 600 words) and 6 turns; every turn resends the whole history, as a chat client or an agent's tool loop does. Sessions run 16 at a time; turns of one session run in order.
- **Seeded and new.** The words come from a seed, so a run is reproducible, and each test run uses seeds no earlier run used, so no cache holds them.
- **Caches empty at the start.** The simulator has no cache reset, so `scripts/up.sh` restarts the model servers before every test.
- **Time to first token, after the first turn.** Every request streams; the load generator records when the first content token arrives. The first turn of a session has nothing cached anywhere, so the comparison that matters is over turns 2 to 6, reported at the median and the 90th percentile. A stream that ends without `[DONE]` is a failure, not a fast answer.
- **The cache hit rate from the servers themselves**, as the change in `vllm:prefix_cache_hits_total` over `vllm:prefix_cache_queries_total` across the run, summed over the replicas present at both ends.
- **Thresholds as ratios inside the measured margin.** The router must reach at most 0.6 of round-robin's median and at least 20 points more cache hits, in every round, where about 0.35 and 38 points are measured.

## Consequences

- One fixed shape of traffic. Shorter shared prefixes or more replicas change the size of the gain; the load generator takes `--sessions`, `--turns`, `--system-words` and `--concurrency` to try others, and the tests use the defaults.
- The simulator's 1024-token default context window is too short for this load; the model servers run with `--max-model-len=8192`, as a real deployment would set.
