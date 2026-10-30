# 5. The same comparison on one L4, shared by four vLLM replicas

Proposed, 2026-10-30.

## Context

ADR 1 put the routing comparison on simulated model servers first and promised a weekly run on a real GPU second: what the simulator shows as a ratio, the GPU shows in seconds and dollars. The simulator charges prefill by a formula. A GPU charges it in compute, shared with every other request in flight, and its time to first token also holds the work a cache hit does not save: each step reads the model's weights whatever was cached.

Routing needs more than one model server, and the comparison the kind run makes uses four: with two, round-robin would find a conversation's replica half the time, and the test would ask less of the router. The validation account's quota for G and VT instances is 8 vCPUs in us-east-1, and the flagship's weekly GPU run takes 4 of them while it runs, on Thursdays. The budget is the tighter limit: about $1.50 a run, and about $20 a month together with the flagship's AKS leg. One g6.xlarge, one NVIDIA L4 and four vCPUs at $0.80 an hour on demand, fits it; two would cost $1.61 an hour before the control plane and the CPU node, for a run that lasts most of an hour.

## Decision

- **The same comparison.** `tests/e2e.sh` with its thresholds, the load from `loadgen/loadgen.py` through `scripts/run-load.sh`, the router from `deploy/router-values.yaml` through `scripts/up.sh`, and the round-robin Service: the files the kind run uses, unchanged except that the load names the model the servers serve. Only the model servers differ (`deploy/gpu/model-server.yaml`).
- **Four vLLM replicas on one L4, by time-slicing.** NVIDIA's device plugin v0.20.1 offers the L4 as four `nvidia.com/gpu` (`deploy/gpu/device-plugin.yaml`), and each replica asks for one. Time-slicing shares the GPU's time, not its memory, so each vLLM is told to take a fifth of it (`--gpu-memory-utilization=0.2`), and the four start one at a time, a StatefulSet with ordered start-up, because vLLM sizes its KV cache from the memory it finds free when it starts. The L4 has no MIG. MPS would run the four replicas' kernels at once, and needs a control daemon beside the device plugin; four L4s would need four times the quota and the price.
- **A small open model, pinned file by file.** Qwen2.5-1.5B-Instruct, Apache-2.0, at commit `989aa7980e4cf806f80c7fef2b1adb7bc71aa306` of its Hugging Face repository, every file the server reads checked against its sha256 in each pod before vLLM starts. Dense attention, and a chat template that renders earlier turns as they were sent, so a conversation's history is a prefix of its next turn, as the load assumes. Models with linear-attention layers, and templates that rewrite earlier turns (the thinking models'), change what a prefix cache can hold, and are not what this measures.
- **vLLM v0.32.0, by digest.** Its linux/amd64 build with zstd layers, 7.3 GB against 9.2 GB for the gzip one, which the GPU node pulls while it bills. It runs CUDA 13.0, which needs driver 580 or later; EKS's AL2023 NVIDIA image carries 580.178.04 (v20261026). The server runs as a user with no privileges and a read-only root filesystem.
- **On EKS, the GPU node for the model servers alone.** The g6.xlarge is tainted so only the four replicas land on it; the router, its Endpoint Picker, the load generator and CoreDNS run on one m7i.large, so the router's path does not compete with vLLM for the GPU node's four vCPUs. Two public subnets and no NAT gateway: the nodes pull about 10 GB a run, which a NAT gateway bills by the gigabyte, and nothing reaches the nodes from outside. The cluster's API answers the runner's address alone (`eks/`, its plan checked against a mocked provider on every push, `eks/tests/`).
- **Capacity first.** The run's first apply makes the cluster and the CPU node. Then `scripts/eks.sh reserve` asks for an On-Demand Capacity Reservation of one g6.xlarge in each of the run's zones in turn (every zone that offers both instance types, up to four), and the second apply makes the GPU node in the zone that gave one, into that reservation. A zone with no L4 refuses a reservation at once and for nothing; a node group's launches are refused one by one until it gives up. The reservation is targeted, so nothing else takes it, and limited: AWS ends it by itself two and a half hours after the run starts if no destroy has. If no zone has an L4, the run stops there, having paid for a quarter of an hour of the control plane and the CPU node.
- **An A10G when no zone has an L4, and named as one.** Each round of the reservation asks every zone for a g6.xlarge first, and only when none has one, every zone for a g5.xlarge: one NVIDIA A10G, the same 24 GB and four vCPUs, the same image and settings, under the same quota, from its own capacity pool, at $1.006 an hour against the L4's $0.8048. The check after start-up reads the GPU's name with `nvidia-smi` inside the model servers and the instance type from the node, and refuses a pairing it does not know; the results, the run's summary and the README name the card as `NVIDIA L4 (g6.xlarge)` or `NVIDIA A10G (g5.xlarge), fallback: no L4 in any zone`, and an A10G's numbers never share a row with an L4's. `tests/gpu-card.sh` shows that check its breaks on every push (`tests/gpu-card-plants.tsv`), a run on an A10G that reports an L4 among them.
- **What an output token costs.** The model servers' own count of the tokens they generated (`vllm:generation_tokens_total`), over the wall time of each route's runs, at the on-demand price the run reads from the AWS Price List API: the GPU node alone, and with the CPU node and the control plane. This is the price at this load, 16 conversations at a time with answers of up to 24 tokens, not the L4's capacity.
- **Inside the budget before anything is billed.** A preflight job asks AWS whether the creation role's trust names this repository, whether the GPU quota is free (the flagship's run uses it too), and what the instances cost an hour, and refuses to start a run that could cost more than $1.50 if every billed job ran to its timeout, on the dearer of the two GPUs: 45 minutes for the up job and 25 for the down job, $1.43 on the A10G and $1.20 on the L4. Each apply is interrupted before its step's timeout, so Terraform writes its state and releases its lock. Teardown runs whatever happened: it removes a lock a stopped Terraform left, and a destroy that fails is followed by the node groups deleted, any instance of the run terminated and its reservation cancelled through the AWS CLI, and a second destroy; then nothing may be left with the run's tags or of any earlier run. The next run's sweep destroys any state an earlier run left. The cost is computed from each instance's own launch and termination and the reservation's start, and a run above $1.50 fails.
- **Weekly, on Sunday,** behind the repository variable `AWS_VALIDATION_ENABLED`: no other weekly run in the account takes Sunday (aws-eks-reference-platform runs on Wednesday, the flagship on AWS, with its GPU, on Thursday), and the preflight still refuses to start while the GPU quota is taken. By hand on main when the dispatch says SPEND; a dispatch without it runs the free preflight alone.

## Consequences

- The four replicas take turns on one GPU. A request on one waits while another's kernels run, and each replica reads its own copy of the weights at every step, so the latencies are those of a shared L4, not of one vLLM with the whole GPU. Both routes run on the same four.
- Each replica's KV cache is what is left of its fifth after the weights, about a gigabyte. Round-robin spreads every conversation over every replica and fills each cache with all of them; the router keeps each conversation on one. What that does to evictions is part of what is measured.
- vLLM's processes share the GPU node's four vCPUs: each replica's engine loop and API server.
- The planted breaks run on kind, where each costs nothing. The GPU run runs the same checks, which kind shows their breaks every day, and its own checks of the GPU and the weights without plants of their own.
- A new vLLM, model or driver changes the weekly numbers. A number in the README is copied from the run it names.

## On AWS, 2026-10-30: no L4 to be had

No run has reached the comparison yet. Every billed run was torn down, and the residue check of the last one found nothing of it or of any earlier run. The runs, and what each changed:

| Run | What happened | Cost, on-demand estimate |
|---|---|---|
| [41067783938](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/runs/41067783938) | The cluster and the CPU node came up; the GPU node group was still creating 19.5 minutes later, with no g6.xlarge launched, when the step's timeout killed Terraform. Its S3 lock stayed and refused both destroys; the fallback deleted the node groups through the CLI. | about $0.12 |
| [41075374482](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/runs/41075374482) | The sweep removed that lock and destroyed the 23 resources left. The reservation, asked through Terraform after the cluster, had no answer after five minutes; it turned out `failed`, which bills nothing. | about $0.05 |
| [41080156587](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/runs/41080156587) | Reserved through the CLI after the cluster: us-east-1a, b, c and d refused, InsufficientInstanceCapacity. | about $0.04 |
| [41083558573](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/runs/41083558573) | Reserved before anything else: all five zones that offer both instance types (a, b, c, d, f) refused. Nothing was made. | $0.00 |
| [41084495170](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/runs/41084495170) | Seven rounds over the five zones, 15:52 to 16:06 UTC: no g6.xlarge in any. Nothing was made; residue clean. | $0.00 |

CloudTrail in the account holds 14 refused g6.xlarge launches in us-east-1a and 18 in us-east-1b on that day, all `Server.InsufficientInstanceCapacity`. The flagship's GPU run got its g6.xlarge in its two zones, us-east-1a and b, between 03:09 and 05:14 UTC that day (its run 40995734934). L4 capacity in the region comes and goes, and on that afternoon there was none.

What the runs changed, all of it in the Decision above: the L4 is reserved before anything is made, through the CLI and imported into the state; each apply is interrupted before its step's timeout; the down job removes a stale lock and deletes node groups through the CLI when a destroy fails; the sweep destroys any earlier run's state and stops any earlier cluster's instance or reservation that no state holds; the residue check counts only an instance state EC2 names.

## When there is no L4

The run asks for one g6.xlarge for fifteen minutes and stops when none comes, at no cost. A week without an L4 is a week without a GPU number; nothing here hides it. If that keeps happening, the GPU types under the same quota are, at on-demand prices from the AWS Price List API in preflight run [41087587141](https://github.com/heyvaldemar/kubernetes-llm-inference-gateway/actions/runs/41087587141):

| Instance | GPU | vCPUs (of the 8) | An hour | Fits the comparison |
|---|---|---|---|---|
| g6.xlarge | L4, 24 GB | 4 | $0.8048 | yes: the run as decided |
| g6.2xlarge | L4, 24 GB | 8 | $0.9776 | the same L4 from the same hosts, so no help when L4s are gone; all of the quota, so never beside the flagship's run |
| g5.xlarge | A10G, 24 GB | 4 | $1.006 | yes: the same memory, the same vLLM image (CUDA 13 runs on Ampere), its own capacity pool. The most a run could cost is $1.74 at today's timeouts, so the up job's 55 minutes would come down to 45 for $1.50 |
| g4dn.xlarge | T4, 16 GB | 4 | $0.526 | no: 16 GB holds four copies of the model with almost no KV cache, and the T4 has no bfloat16 |

The g5.xlarge is the fallback, built as the Decision above says (2026-10-30, after these runs): the same rounds for it when no zone has an L4, the card named, its numbers apart.

## How to explain this to a customer

The router's claim is that sending a conversation back to the server that already holds it costs less than spreading conversations evenly. On a laptop that is a ratio from a simulator. Here the same test runs on a real GPU with a real model each week, and each answer has a price: what a million generated tokens cost on each route, at AWS's on-demand price, on a GPU four servers share, as a small deployment would share one.
