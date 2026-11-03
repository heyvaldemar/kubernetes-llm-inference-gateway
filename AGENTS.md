# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

The README makes four kinds of claim, and each has a check or a named run behind it. A claim with neither is not written.

- **Routing by prefix cache beats round-robin on the same four model servers.** `tests/e2e.sh` on a fresh kind cluster, run by `.github/workflows/e2e.yml` every day, on every push to main and on every pull request to main. It requires, in both rounds: every image a pod runs named in `images.lock`, in every namespace on kind; every request answered on both routes; the router's time to first token after the first turn at most 0.6 of round-robin's at the median; the router's prefix cache hits at least 20 points above round-robin's. `tests/plants.tsv` shows each check its break. The table under "What it measured" is a local run on 2026-10-30; the live numbers are the badges.
- **What a failing replica does to each route.** `tests/failure-modes.sh`, run by `.github/workflows/failure-modes.yml`, records the numbers and gates only that each scenario happened, with round-robin as the witness (ADR 4). `tests/failure-plants.tsv` shows those checks their breaks. The README's table is run 41012248244, named beside it.
- **The same comparison on a GPU, and what a token costs.** `.github/workflows/gpu.yml` on EKS, with the runs named beside every number and the card named beside every run. The GPU run's time threshold is replayed on saved GPU runs by `tests/gpu-judge.sh`, the card naming by `tests/gpu-card.sh`, and the Terraform by `terraform test` against a mocked provider, all on every push.
- **What it costs.** The GPU run's own preflight bound and cost step (`scripts/eks.sh preflight` and `cost`), copied from the runs that printed them.

On kind the image check reads every pod in every namespace: this repository's, named by digest, and kind's own (the control plane, CoreDNS, kube-proxy, kindnet, the storage provisioner), named as those pods name them, by tag, inside the node image `cluster/kind.yaml` pins by digest. It knows kind by a node whose provider ID starts `kind://`; the plant that puts a pod in `kube-system` is what shows it still does. On EKS it reads the default namespace only: the router's Envoy and EPP, the model servers and the load Jobs. EKS's own pods in `kube-system`, and the device plugin this repository deploys there, are not compared with `images.lock`. Write no wider claim than that.

It is a reference, not a product, and nothing says otherwise: no wording about production use, live deployments or a certification in the README, the decision records or a release.

## Before changing anything

- Read the decision record that covers it, under `docs/decisions/`: the simulator before the GPU (ADR 1), the plain Service as the baseline (ADR 2), the load and where it is measured (ADR 3), failure modes recorded and not gated (ADR 4), the GPU run (ADR 5). A change to a decision adds a dated section to its record, as ADR 5's 2026-11-01 section does, or a new record in the same format, linked from the README's paragraph on decision records.
- The kind run and the GPU run share `tests/e2e.sh`, `scripts/up.sh`, `scripts/run-load.sh`, `loadgen/loadgen.py` and `deploy/router-values.yaml` (ADR 5). A change to any of them changes the GPU run, which cannot be proved on a branch (below).
- `scripts/up.sh` restarts the EPP after every `helm upgrade`: the chart puts no checksum of the plugins' ConfigMap on the pod, and without the restart a test of a changed config measures the previous one. The plant for "no prefix-cache affinity" went unnoticed until that line. Keep it.
- The simulator's flags in `deploy/model-server.yaml` (prefill overhead, prefill per token, inter-token latency, cache size) are what the kind numbers measure. The README's "What these numbers are about" quotes them; change both in one commit.
- `tests/e2e.sh` prints `OK`, `FAIL` and `MEASURED` lines, and with `E2E_RESULTS` set writes them as the checks and measurements `scripts/status.py` reads. The text before `: ` in a `MEASURED` line names its badge file on the `status` branch (`badge-router-ttft-after-the-first-turn.json`, `badge-prefix-cache-hits.json`), so renaming one breaks a README badge unless the README changes with it. A measured line is `label: value (detail)`, short, with units, and never `X · label: value`: heyvaldemar.com folds that shape into a per-model table.
- Before pushing, run what needs no cluster: `shellcheck scripts/*.sh tests/*.sh`, `./tests/gpu-card.sh`, `./tests/gpu-judge.sh`, each with its plants (`PLANTS=tests/gpu-judge-plants.tsv python3 -I tests/plant-violations.py -- bash tests/gpu-judge.sh`), and, with Terraform 1.16.5, `terraform -chdir=eks init -backend=false -input=false -lockfile=readonly` then `terraform -chdir=eks test`.

## A check is trusted only after it has failed

A new or changed check ships with the break it exists for, as a row in its plant table: the file, the text to break, its replacement, and what the test must notice, each field JSON-encoded. `tests/plant-violations.py` runs the test on an untouched copy, which must pass, then on one copy per row, each of which must fail.

| Table | Test | Where it runs |
|---|---|---|
| `tests/plants.tsv` | `tests/e2e.sh`, after `scripts/up.sh` | e2e job, on main, the schedule and dispatches; not on pull requests |
| `tests/failure-plants.tsv` | `tests/failure-modes.sh` | failure-modes `release` job, the same events |
| `tests/gpu-card-plants.tsv` | `tests/gpu-card.sh` | lint job, every run |
| `tests/gpu-judge-plants.tsv` | `tests/gpu-judge.sh` | lint job, every run |
| `eks/tests/plants.tsv` | `terraform -chdir=eks test` | Terraform job, every run |

A plant quotes the text it breaks, so an edit to that text (the Envoy digest, the `RATIO_MAX` line in `tests/e2e.sh`, `RATIO_PERCENTILE` and `RATIO_MAX` in `gpu.yml`, a card case in `scripts/eks.sh`) updates the row in the same commit, or the run reports it stale and fails. The GPU run's own break is a dispatch with `plant: random-picker`, which must fail (run 41319020421); only the maintainer starts one. A saved GPU run under `tests/fixtures/gpu/<run id>/` is that run's `results-gpu` artifact unchanged, with an `expect` file: `pass` or `fail`, then what the run was.

## Gates, and why they sit where they do

- **kind: the median at most 0.6, and 20 points of cache hits, in every round** (`tests/e2e.sh`, ADR 1 and 3). The simulator measures about 0.35 and about 38 points, so a failure means the routing broke, not that a run was unlucky.
- **GPU: the 90th percentile at most 0.6** (`RATIO_PERCENTILE: "90"` and `RATIO_MAX: "0.6"` in `gpu.yml`; the hit-rate check is kind's). On a card four replicas share, the router's median is the card's step, 205 to 213 ms on the L4 whatever was cached; the tail is where a miss lands. Working routers measured 0.21 to 0.45 there and a router picking at random 0.99, so 0.6 sits 0.15 above the slowest working round and 0.39 below the broken ones. An interim 0.8 on the median sat 0.07 from both and was replaced the same day (ADR 5, 2026-11-01). `tests/gpu-judge.sh` replays the four saved runs against the values it reads from `gpu.yml`.
- **Failure modes: no gate on the router** (ADR 4). A router release that changes how it treats a failing replica changes the weekly numbers and turns nothing red; reading them is a person's job.
- **Cost: $1.50 a GPU run** (`MAX_RUN_USD`). The preflight refuses a run that could cost more if every billed job ran to its timeout, reading the up job's 45 minutes and the down job's 25 from `gpu.yml`: $1.43 on the A10G, $1.20 on the L4. The cost step fails a run above it, and the GPU reservation ends by itself 150 minutes after the run starts. A timeout is part of the cost bound.

A gate moves only with a dated section in its decision record that names the runs it was set from. It is never moved to get a run green.

## Numbers

A number is read from a run and names it. Which run writes what:

- **e2e.yml** (kind; daily, on pushes to main and on pull requests): the artifacts `results`, each load's JSON, kept 90 days, and `e2e-results`, the checks and measurements, kept 30. After every run on main, `.github/workflows/status.yml` runs `scripts/status.py` and replaces the one-commit branch `status`: `status.json`, the badge files the README's second row reads, and a README. The fleet's catalog reads `status.json` for heyvaldemar.com. Nothing edits that branch by hand.
- **failure-modes.yml** (kind; Monday, and on pushes and pull requests that touch its paths): the artifacts `failure-modes-release` and `failure-modes-health-filter`, kept 90 days. No status file.
- **gpu.yml** (EKS; Sunday, or by hand): the artifact `results-gpu`, kept 90 days, and the run's summary, which holds the card, the token prices and the cost. No status file; nothing of it reaches the `status` branch.

The README, the decision records, the CHANGELOG and the release notes carry numbers copied from the runs they name. A GPU number names its card as `NVIDIA L4 (g6.xlarge)` or `NVIDIA A10G (g5.xlarge), fallback: no L4 in any zone`, and an A10G's numbers never share a row with an L4's. No weekly GPU result is claimed until a scheduled run passes. When runs differ, find what changed (the card, the zone, the runner, an upstream release) before calling it noise: the L4's median is how the GPU threshold moved to the 90th percentile.

## Pins

- **`images.lock`**: every image by digest (the simulator, the EPP v1.0.0, the EPP main build for the health filter, Envoy, vLLM, NVIDIA's device plugin, the Python the load Jobs run), the router chart and its version, the Gateway API Inference Extension version, and kind and helm by version and sha256 (linux amd64).
- **Copies of those digests**: `cluster/kind.yaml` (the kind node), `deploy/model-server.yaml`, `deploy/router-values.yaml` (Envoy and the EPP), `deploy/router-health-filter.yaml`, `deploy/sick-replica.yaml`, `deploy/gpu/model-server.yaml`, `deploy/gpu/device-plugin.yaml`, and the Envoy and kind node rows of `tests/plants.tsv`. Move every copy in one commit. The kind run catches a copy that differs from `images.lock` for any pod it runs; the GPU manifests' copies are exercised only by a GPU run.
- **The InferencePool CRD**: `scripts/up.sh` applies the Gateway API Inference Extension's `v1-manifests.yaml` from its release URL at `GAIE_VERSION`, by version, with no checksum.
- **The kind node**: by digest in `cluster/kind.yaml`, kind v0.33.0's default node for Kubernetes v1.37.0, with the same value as `KIND_NODE_IMAGE` in `images.lock`; `scripts/up.sh` refuses a `cluster/kind.yaml` that names another. The images kind's own pods run are inside it and listed in `images.lock` as those pods name them, by tag. A kind bump moves the binary's version and sha256, the node image in both files, and that list, in one commit; the e2e run lists any image the new node brings that `images.lock` does not name.
- **The model**: Qwen2.5-1.5B-Instruct at Hugging Face commit `989aa7980e4cf806f80c7fef2b1adb7bc71aa306`, every file the server reads checked against its sha256 in each pod, in `deploy/gpu/model-server.yaml`.
- **The GPU run's cluster**: Terraform 1.16.5 (`e2e.yml` and `TERRAFORM_VERSION` in `gpu.yml`), the AWS provider in `eks/.terraform.lock.hcl` (`init -lockfile=readonly`), EKS's Kubernetes version in `eks/variables.tf`. The AL2023 NVIDIA node image is EKS's release for that version at apply time, not pinned; ADR 5 names the driver it carried.
- **Actions** by commit SHA, moved by one grouped Dependabot pull request a week (`.github/dependabot.yml`). `dependabot-automerge.yml` merges it only after its E2E run is green, then dispatches E2E on main.
- **Not pinned**: kubectl, ShellCheck and python3 come from the runner image.

No script here watches for newer releases; a bump is by hand, with the new digest read from the publisher. When an llm-d release carries the `endpoint-health-filter`, that release replaces the main build in `images.lock` and `deploy/router-health-filter.yaml`, and the experimental flag goes (ADR 4).

## Proving a risky change

A change to `deploy/`, `scripts/`, `tests/`, `loadgen/`, `images.lock` or a workflow runs on a branch before it reaches main:

```bash
gh workflow run e2e.yml --ref <branch>
```

That runs the lint job (ShellCheck, the GPU card and threshold checks with their plants), the Terraform tests with theirs, and the kind comparison with its plants, at no cost. A pull request to main runs E2E without the plants. A second dispatch on the same ref waits for the first. `scripts/status.py` reads runs on main only, so a branch run never moves the badges. Check the run's `e2e-results` artifact when a change touches what `tests/e2e.sh` prints.

`failure-modes.yml` runs on kind at no cost, in two jobs: the released router with its plants, about 20 minutes, and the health-filter build, about 5. Pushes and pull requests that touch its paths start it, and those paths include all of `scripts/` and `images.lock`. Dispatch it on a branch only to prove a change to the scenarios or to what they run.

The GPU run cannot be proved on a branch: its jobs run only on main. A change to `deploy/gpu/`, `eks/`, `scripts/eks.sh`, `gpu.yml` or the shared files above is proved as far as the lint and Terraform jobs go, then waits for Sunday's run or the maintainer's. Say that in the commit and the CHANGELOG: not yet run on a GPU.

## The GPU run costs money

`gpu.yml` bills the AWS validation account that aws-eks-reference-platform set up, through GitHub's OIDC token and the `aws-validation` environment; no credential is stored here. It runs only on Sunday's schedule while the repository variable `AWS_VALIDATION_ENABLED` is true, or when the maintainer dispatches it on main with `SPEND`. The maintainer approved it weekly on 2026-10-28, about $20 a month together with the flagship's AKS leg. The account's GPU quota is shared with the flagship's Thursday run; aws-eks-reference-platform runs on Wednesday.

An agent does not start it, with `SPEND` or without (the free preflight still assumes the creation role in the account), does not change the repository's variables or environments, and does not run `scripts/eks.sh`, `terraform apply` or the AWS CLI against the account from anywhere. If a run left something behind, the next run's sweep and residue check are the cleanup; tell the maintainer, do not clean by hand.

## Releases

- Fill `CHANGELOG.md` `[Unreleased]` in the same commit as the change.
- A release commit, `Release X.Y.Z`, turns `[Unreleased]` into `[X.Y.Z] - <date>` and adds the tag's link at the bottom.
- Tag only a commit whose E2E is green on main, or a docs-only commit right after one, and name that run in the notes, with the Failure modes run when one ran on it, as 1.2.0 names 41096491913 and 41096492137. The release title is `X.Y.Z: <what changed>`; the notes say what is new, with the runs, cards and costs behind each number, and end with "Not production."
- Publishing runs `.github/workflows/release-assets.yml`: a `git archive` of the tag, its keyless cosign bundle and SLSA provenance, and a last job that verifies both and shows each a tampered copy, which both must refuse. Verify them the way a stranger would, with `cosign verify-blob` and `slsa-verifier verify-artifact --source-tag <tag>`, as the workflow's header shows.

## Writing

Plain and specific. No em dashes, no marketing words, no claim the evidence does not carry. Name runs, commits, cards and files, and date a number. Commit subjects follow the log: a plain sentence, often after the area (`GPU run:`, `README:`, `ADR 5:`, `ci:`), and `Release X.Y.Z`. Commits are authored `Vladimir Mikhalev <10498744+heyvaldemar@users.noreply.github.com>` and carry no AI attribution lines or trailers.

## Never

- Loosen a gate to get a run green: `RATIO_MAX`, `HIT_GAIN_MIN`, `RATIO_PERCENTILE`, the every-round rule, the image check, a GPU timeout or `MAX_RUN_USD`. No plant edited until it stops failing, no `expect` file flipped, no fixture edited.
- Type a measured number by hand, into the README, a decision record, the CHANGELOG, release notes, a fixture or the `status` branch. Copy it from the run it names, or leave it out.
- Edit the `status` branch by hand.
- Print a secret or a credential, or pass one as a command-line argument. This repository stores none: AWS is reached through OIDC, and `status.yml` hands its token to git through git's environment, not its command line.
- Make cloud resources outside the existing workflows: no AWS CLI, Terraform or eksctl against any account, and no other cloud, to test a change. kind is where a change is tried.
- Start `gpu.yml`, or change what lets it run.
- Put an A10G's number in a row with an L4's, or call a fallback run an L4 run.
- Claim a weekly GPU result before a scheduled run passes.
- Run the comparison's router on llm-d's main build. The comparison measures the router as released; the main build and its health filter belong to `tests/failure-modes.sh` alone.
