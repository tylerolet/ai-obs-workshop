# AI Observability Workshop

A self-contained AI inference platform running entirely in GitHub Codespaces on Kubernetes (k3d) — no GPU required.

Derived from the Daystrom Mini multi-cloud architecture, consolidated into a codespace-friendly deployment with a tiny quantized LLM (Qwen2.5-0.5B via llama.cpp).

## Architecture

```
┌─────────────┐       ┌──────────────────────┐       ┌───────────────┐
│   web-app   │──────▶│ request-orchestrator  │──────▶│ safety-gateway│
│  (Next.js)  │       │   (Java/Spring Boot)  │       │  (Python/gRPC)│
└─────────────┘       └──────────┬───────────┘       └───────┬───────┘
                                 │                            │
                    ┌────────────┼────────────┐               ▼
                    ▼            ▼            │        ┌─────────────┐
             ┌────────────┐ ┌──────────┐     │        │ mock-safety │
             │prompt-cache│ │model-    │     │        │  (Python)   │
             │(Java/gRPC) │ │router    │     │        └─────────────┘
             │   + Redis  │ │(Python/  │     │
             └────────────┘ │ gRPC)    │     │
                            └────┬─────┘     │
                                 │           │
                                 ▼           │
                          ┌────────────┐     │
                          │ inference- │     │
                          │ pool (Java)│     │
                          └─────┬──────┘     │
                                │            │
                                ▼            │
                          ┌────────────┐     │
                          │ llama.cpp  │     │
                          │ (Qwen 0.5B)│     │
                          └────────────┘     │
```

### Services

| Service | Language | Transport | Description |
|---------|----------|-----------|-------------|
| **web-app** | TypeScript (Next.js 14) | HTTP | Chat UI |
| **request-orchestrator** | Java (Spring Boot) | REST → gRPC | Central request handler |
| **prompt-cache** | Java (Spring Boot) | gRPC | Prompt prefix caching via Redis |
| **safety-gateway** | Python | gRPC | Safety classification (calls mock) |
| **model-router** | Python | gRPC | Routes requests to inference pool |
| **inference-pool** | Java (Spring Boot) | HTTP | Reverse proxy to llama.cpp |
| **llama-cpp** | C++ (pre-built) | HTTP | OpenAI-compatible LLM inference |
| **mock-safety** | Python | HTTP | Returns "safe" for all requests |

### Infrastructure (in-cluster)

- **Redis** — prompt cache storage
- **PostgreSQL** (pgvector) — conversation/usage data
- **OTel Collector** — receives traces/metrics, exports to Dynatrace

## Quick Start

### Prerequisites

- GitHub Codespace (4-core, 16GB RAM recommended)
- Dynatrace tenant with API token (optional, for full observability)

### 1. Open in Codespace

Click **Code → Codespaces → New** on this repository. The devcontainer installs k3d, kubectl, Maven, Python, and Node.js automatically.

### 2. Set Dynatrace Secrets (Optional)

In your Codespace settings, add secrets:
- `DT_ENDPOINT` — e.g. `https://{env-id}.live.dynatrace.com/api/v2/otlp`
- `DT_API_TOKEN` — token with `openTelemetryTrace.ingest` + `metrics.ingest` scopes

### 3. Deploy

```bash
make up
```

This will:
1. Create a k3d cluster with a local registry
2. Build all service container images
3. Deploy to the cluster (including downloading the 400MB model)
4. Wait for all pods to be ready

### 4. Use

- **Chat UI**: http://localhost:3000
- **API**: `curl -X POST http://localhost:8080/api/chat -H 'Content-Type: application/json' -d '{"message":"hello","model":"large"}'`

### 5. Observe

Traces flow: web-app → request-orchestrator → {prompt-cache, safety-gateway, model-router} → inference-pool → llama-cpp

All spans are exported to your Dynatrace environment via the OTel Collector.

## Commands

| Command | Description |
|---------|-------------|
| `make up` | Create cluster and deploy everything |
| `make down` | Tear down cluster |
| `make status` | Show pod status |
| `make logs SVC=model-router` | Tail logs for a service |
| `make build-svc SVC=model-router LANG=python` | Rebuild and redeploy a service |
| `make restart SVC=inference-pool` | Restart a deployment |
| `make test` | Quick smoke test |

## Resource Budget (Codespace 4-core / 16GB)

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| llama-cpp | 500m | 1Gi |
| request-orchestrator | 100m | 256Mi |
| prompt-cache | 100m | 256Mi |
| inference-pool | 100m | 256Mi |
| model-router | 100m | 192Mi |
| safety-gateway | 100m | 192Mi |
| mock-safety | 50m | 64Mi |
| web-app | 100m | 192Mi |
| redis | 50m | 64Mi |
| postgres | 100m | 256Mi |
| otel-collector | 100m | 128Mi |
| **Total** | **~1.5 cores** | **~3GB** |

## Model

**Qwen2.5-0.5B-Instruct** (Q4_K_M quantization, ~400MB download)
- Runs on CPU via llama.cpp
- 2048 token context window
- Produces coherent but simple responses
- Good enough for demonstrating observability patterns

## Dynatrace for AI Skills

The **[Dynatrace for AI](https://github.com/Dynatrace/dynatrace-for-ai)** skill library is included in this repository as a git submodule under `dynatrace-skills/`. It provides Claude Code skills for AI observability — DQL queries, dashboard templates, problem analysis, and tracing workflows purpose-built for AI/LLM systems.

After cloning, initialize the submodule:

```bash
git submodule update --init --recursive
```

## Observability Scenarios

The architecture supports injecting observability-relevant bugs:

1. **Latency injection** — Add artificial delay in inference-pool or model-router
2. **Cache miss storm** — Flush Redis to trigger cache rebuilds
3. **Safety bottleneck** — Increase safety-gateway processing time
4. **Error injection** — Return 500s from inference-pool

## Project Structure

```
├── .devcontainer/          # Codespace configuration
├── k8s/base/               # Kustomize manifests for k3d
├── proto/                  # Shared protobuf definitions
├── services/
│   ├── java/
│   │   ├── request-orchestrator/
│   │   ├── prompt-cache/
│   │   └── inference-pool/
│   ├── python/
│   │   ├── model-router/
│   │   ├── safety-gateway/
│   │   └── mock-server/
│   └── typescript/
│       └── web-app/
├── scripts/                # Setup and teardown
├── Makefile                # Developer commands
└── README.md
```
