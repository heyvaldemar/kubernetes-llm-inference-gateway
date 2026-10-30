# Security Policy

## Supported versions

The `main` branch. Fixes land there; tags mark releases.

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Email to v@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. This project does not operate a bounty program; researchers who submit valid, responsibly disclosed reports receive public credit in the changelog.

A vulnerability in the llm-d router, the Endpoint Picker or the simulator belongs to [llm-d](https://github.com/llm-d); one in the Gateway API Inference Extension to [kubernetes-sigs](https://github.com/kubernetes-sigs/gateway-api-inference-extension).

## Credentials

The repository holds no credentials. Every image is pinned by digest in `images.lock`.
