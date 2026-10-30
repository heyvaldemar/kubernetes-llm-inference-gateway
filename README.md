# kubernetes-llm-inference-gateway

[![E2E](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/workflows/e2e.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/workflows/e2e.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/heyvaldemar/kubernetes-llm-inference-gateway/badge)](https://scorecard.dev/viewer/?uri=github.com/heyvaldemar/kubernetes-llm-inference-gateway)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/16091/badge)](https://www.bestpractices.dev/projects/16091)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

LLM requests are not ordinary HTTP requests. A chat or an agent resends its whole conversation on every turn, so most of each prompt is a prefix some model server has already processed and may still hold in its KV cache. A load balancer that spreads requests evenly sends most turns to a replica that has not seen the conversation, and that replica processes the whole prefix again.

This repository measures what routing by cache is worth on Kubernetes, with the llm-d router (llm-d 1.0) and the Gateway API Inference Extension, against a plain round-robin Service in front of the same model servers, under the same load, on every push and every day.

## What it measured

The same 32 conversations of 6 turns, 16 at a time, each with a system prompt of its own, through each route to the same four model servers. Local run on kind, 2026-10-30, three rounds; the CI run on a fresh runner re-measures every day.

| | Round-robin Service | llm-d router |
|---|---|---|
| Time to first token, median | 675–677 ms | 94–96 ms |
| After the first turn, median | 267–275 ms | 92–94 ms |
| After the first turn, 90th percentile | 889–917 ms | 105–107 ms |
| Prompt tokens found in a replica's prefix cache | 40–43% | 79% |
| Time for the whole load | 8.3–9.0 s | 4.2–4.3 s |

The first turn of a conversation has nothing cached anywhere, so it costs the same on both routes; every later turn is where the routes differ. The router sends each conversation back to the replica that holds its prefix, so 79% of prompt tokens are found in cache, close to the most this load allows (about 82%, since the first turn of each conversation has nothing to find), against 40–43% when the replica is picked at random.

**Most of the gain came from going back, not from reading the prompt.** With llm-d's prefix-cache affinity filter removed and only its token-load scorer left, the router still found 74–76% of prompt tokens in cache, at 0.35–0.41 of round-robin's time to first token. The turns of a conversation arrive one at a time, and the replica that has just answered one is, at that moment, the least loaded, so load-based picking sends the next turn back to it. Picking a replica at random takes the router back to round-robin's numbers (41–42% of tokens in cache, 1.12–1.27 of its time). The affinity filter is what keeps a conversation on its replica when that replica is not the least loaded; under this load it adds 3 to 5 points of cache hits (79% against 74–76%).

**What these numbers are about.** The model servers are simulated (below), so the numbers measure the routing, not a model. The simulator charges 1 ms of prefill per uncached token and 10 ms per output token; a GPU with faster prefill gains less time from each cache hit, a longer shared prefix gains more. The ratio is what transfers; the milliseconds come from the weekly GPU run, which is not built yet.

## How it works

```mermaid
flowchart LR
  L["load generator Job<br/>32 conversations x 6 turns"] -->|"route A"| S["Service<br/>model-server-roundrobin"]
  L -->|"route B"| E["Envoy :8081"]
  E <-->|"ext_proc: which replica?"| P["Endpoint Picker<br/>prefix affinity, then token load"]
  P -.->|"watches"| IP["InferencePool router"]
  S --> M1["sim 1"] & M2["sim 2"] & M3["sim 3"] & M4["sim 4"]
  E --> M1 & M2 & M3 & M4
  IP -.->|"selects app=model-server"| M1
```

- **Model servers**: four replicas of [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim) v1.0.0. It speaks vLLM's OpenAI API and metrics, keeps a prefix KV cache per replica, and charges prefill time only for the prompt tokens that cache does not hold, so a request on the right replica answers sooner for the same reason it would on a GPU, with nothing random in it.
- **Round-robin**: a Kubernetes Service in front of the same four; kube-proxy picks a replica at random for each connection.
- **The llm-d router**: [`llm-d-router-standalone`](https://github.com/llm-d/llm-d-router) v1.0.0, an Envoy proxy that asks the Endpoint Picker over ext_proc which replica of the `InferencePool` gets each request. Its plugins are llm-d's optimized-baseline: prefix-cache affinity, then the replica with the least prefill work queued. Requests for CPU and memory are cut from the chart's production defaults to fit a kind node; the scheduling is unchanged.
- **The load**: [`loadgen/loadgen.py`](loadgen/loadgen.py), standard-library Python, run as a Job inside the cluster. Each conversation resends its full history on every turn, every request streams, and the time to the first content token is measured where a user waits for it. A stream that ends without its `[DONE]` counts as a failure.
- **The cache hits** are the model servers' own counters, `vllm:prefix_cache_hits_total` over `vllm:prefix_cache_queries_total`, read before and after each run.

The reasoning is in three decision records: why the simulator before the GPU ([ADR 1](docs/decisions/0001-measure-routing-on-simulated-model-servers.md)), why a plain Service is the baseline ([ADR 2](docs/decisions/0002-the-baseline-is-a-plain-service.md)), and why the load resends its history and is measured at the first token ([ADR 3](docs/decisions/0003-a-load-that-resends-its-history.md)).

## How it is proven

`tests/e2e.sh` runs the load four times, round-robin and router alternating, each with conversations no cache has seen, and requires:

- every image the cluster runs named, with its digest, in `images.lock`;
- every request answered, on both routes;
- through the router, a median time to first token after the first turn of at most 0.6 of round-robin's, in every round;
- through the router, a cache hit rate at least 20 points above round-robin's, in every round.

Each check is shown the break it exists for (`tests/plants.tsv`, run in CI): the router picking a replica at random, model servers with no prefix cache, an `InferencePool` that selects no model server, a "baseline" that is the router itself, a threshold no honest run can meet, and the chart's own Envoy, a tag with no digest. Each must fail the test.

## When a replica fails

A router that picks the least loaded replica also decides where traffic goes when one of them breaks, and the way it breaks decides which way that goes. A replica that cannot be reached holds on to every request it is given, so it looks busy. A replica that answers every request with an instant error holds none, so it looks idle.

`tests/failure-modes.sh` fails one replica of four in three ways and sends the same open-loop probe through both routes: new single-turn requests on a fixed schedule, as from independent users, whatever happened to the ones before ([ADR 4](docs/decisions/0004-failure-modes-are-recorded-not-gated.md)). On a fresh GitHub runner, [run 41012248244](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/runs/41012248244), 2026-10-30; it runs again every week.

| One replica of four | Requests a second | llm-d router v1.0.0 | llm-d main build, `endpoint-health-filter` first | Round-robin Service |
|---|---|---|---|---|
| Sick: an instant error for every completion, `/health` fine | 10 | 23 of 80 failed (29%) | 5 of 80 (6%) | 23 of 80 (29%) |
| | 50 | 154 of 400 (38%) | 5 of 400 (1%) | 94 of 400 (24%) |
| | 150 | 902 of 1200 (75%) | 0 of 1200 | 295 of 1200 (25%) |
| Unreachable for 6 s, still Ready | 50 | 1 of 304 stalled or failed | 2 of 304 | 59 of 303, up to 3.2 s |
| Crashed (SIGKILL), restarted by the kubelet in about a second | 50 | 6 of 400 failed | 4 of 400 | 2 of 400 |

Each router column is its own job in that run, on its own cluster; round-robin's numbers are from the v1.0.0 job, and the other job's differed by a few points. A crash costs a handful of requests on either route and the count moves from run to run.

**Fast errors look like spare capacity.** At 10 requests a second the router loses what round-robin loses, about a quarter. At 150 it loses three quarters. The healthy replicas are busy, the sick one answers in a millisecond and never is, and token-load scoring ranks it least loaded for nearly every new request. Round-robin stays near a quarter at every rate, because it ignores load in both directions.

**The fix exists, and no release has it.** llm-d's `endpoint-health-filter` ([llm-d/llm-d-router#3326](https://github.com/llm-d/llm-d-router/issues/3326), merged on 2026-10-23, a week after v1.0.0) watches the status of every response: after 5 consecutive 502 or 503 responses it ejects the replica for 30 s, longer each time, up to 5 m. On llm-d's main build, first in the profile ([`deploy/router-health-filter.yaml`](deploy/router-health-filter.yaml)), the sick replica cost the router 5 failed requests before each ejection, whatever the rate. The probe at 10 requests a second ran first and paid for the first ejection, the one at 50 for the second, and at 150 the replica was still out. It is Alpha, so the EPP refuses it without `allow-experimental-plugins`, and it is not in llm-d's optimized-baseline plugins: a router installed from v1.0.0 with these plugins has the first column's numbers.

The unreachable replica is the opposite case. Through the router, 1 of the 304 requests sent while its packets were dropped stalled; that request is in-flight work on the replica, so the ones after it went elsewhere. Round-robin went on handing it a fifth of new requests, each stalled until the packets flowed again.

Without the filter, what ends the sick case is the readiness probe. Both the `InferencePool` and the Service follow the pods' readiness, which turns false after `failureThreshold` failed probes, `periodSeconds` apart, and in the v1.0.0 runs nothing else took the sick replica out. A probe that proves only that the HTTP server answers keeps a replica that fails every completion in the pool, and under load-aware routing the price of that grows with the load.

## Quickstart

```bash
./scripts/up.sh       # kind, the InferencePool CRD, four model servers, the router
./tests/e2e.sh        # the comparison; RESULTS=<dir> keeps each run's JSON
./tests/failure-modes.sh   # one replica fails three ways, both routes
./scripts/run-load.sh router http://router-epp:80 any-seed --sessions 64 --turns 8
kind delete cluster --name ilg    # teardown
```

Needs Docker, kind, helm and kubectl. Every image is pinned by digest in [`images.lock`](images.lock), and the test fails if the cluster runs any image that file does not name, the ones a chart brings by default included.

## What it costs

Nothing beyond a machine with Docker: the cluster is kind, the model servers are simulated, and nothing reaches a cloud account. One test run, cluster included, takes about three minutes on a GitHub runner; the planted breaks take about thirteen more.

## What it does not do

- **No GPU yet.** The weekly run on an NVIDIA L4 with vLLM and a real model, with cost per million tokens, is the next step; until it exists, nothing here is a claim about a GPU.
- **Failure handling is measured, not fixed.** The table above is one failing replica of four, on one node. The comparison runs the v1.0.0 router without the health filter, because that is what the release gives; the filter runs only in the failure scenarios.
- **One router configuration.** llm-d's other paths (precise prefix-cache routing over KV events, prefill/decode disaggregation, predicted-latency routing) are not exercised.
- **Not production.** It is a reference: it runs on kind, on a laptop or a CI runner, at no cloud cost.

## Questions, bugs and changes

Open an [issue](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/issues). Security reports go privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE).
