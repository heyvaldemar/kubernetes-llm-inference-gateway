# 2. The baseline is a plain Kubernetes Service

Accepted, 2026-10-30.

## Context

"Routing by cache is faster" needs a "than what". The candidates were another inference gateway, an Envoy or ingress load balancer with its own algorithm (least-request, ring hash), or a plain Kubernetes Service.

## Decision

The baseline is a plain `ClusterIP` Service in front of the same four replicas, which is what a team running vLLM behind a Deployment has before it adopts anything: kube-proxy picks a backend for each new connection, and the load generator opens one connection per request.

## Consequences

- The comparison answers the question a team actually has: what do we gain over what we run today.
- It does not compare the llm-d router with other cache-aware schemes. A consistent-hash load balancer on a session header would also keep a conversation on one replica, but needs the client to send a stable key and ignores load; llm-d's affinity reads the prompt itself and weighs queued work. That comparison is a separate question, not answered here.
- Both routes reach the same pods, so the model servers, their caches and their latency settings are identical by construction; the only difference is who picks the replica.
