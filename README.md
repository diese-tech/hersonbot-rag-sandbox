# HersonBot RAG Sandbox

Local-first Retrieval-Augmented Generation (RAG) sandbox for the Grid homelab.
It ingests plain-text documents, stores local embeddings in Qdrant, and returns
the most relevant chunks through a FastAPI API. No cloud API is required for the
current retrieval flow.

Operators should use [RUNBOOK.md](RUNBOOK.md) for the full operational guide:
architecture, startup, smoke tests, backup/restore, safety boundaries, and
known limitations.

## What Is In This Repo

| Path | Purpose |
| --- | --- |
| `api/` | FastAPI application, ingestion, retrieval, embedding config |
| `docs/` | Sample ingestible `.txt` documents |
| `scripts/` | Operator scripts for smoke testing and Qdrant backup/restore |
| `.env.example` | Runtime configuration template |
| `RUNBOOK.md` | Production-style operations guide |

The Docker Compose stack is expected at `/opt/grid/stacks/hersonbot/` on the
target homelab host. This repo contains the application source and operator
scripts, not the stack definition.

## Stack

| Component | Role |
| --- | --- |
| FastAPI | Ingestion and retrieval API |
| Qdrant | Persistent vector database |
| `sentence-transformers` | Local embeddings with `all-MiniLM-L6-v2` |
| Docker Compose | Service orchestration on the homelab host |

All documented service ports are bound to `127.0.0.1` on the host. Do not expose
the API or Qdrant directly to the network without a separate security review.

## Quickstart

On the Grid host:

```bash
# 1. Copy env template on first setup
cp /opt/grid/repos/hersonbot/.env.example /opt/grid/stacks/hersonbot/.env

# 2. Start the stack
cd /opt/grid/stacks/hersonbot
docker compose up -d

# 3. Check health
curl http://127.0.0.1:8100/health
curl http://127.0.0.1:6333/healthz
```

Expected API health response:

```json
{"status":"ok"}
```

## Ingest A Document

Files must be `.txt` files under `/opt/grid/repos/hersonbot/docs/`.

```bash
curl -X POST http://127.0.0.1:8100/ingest/file \
  -H "Content-Type: application/json" \
  -d '{"path": "sample.txt"}'
```

Raw text can be ingested directly:

```bash
curl -X POST http://127.0.0.1:8100/ingest/text \
  -H "Content-Type: application/json" \
  -d '{"doc_id": "my-note", "text": "HersonBot lives on grid-node-01."}'
```

## Query

```bash
curl -X POST http://127.0.0.1:8100/query \
  -H "Content-Type: application/json" \
  -d '{"query": "what is HersonBot", "top_k": 3}'
```

The response includes the original query plus ranked chunks with source document
metadata and similarity scores.

Interactive API docs are available while the API is running:

```text
http://127.0.0.1:8100/docs
```

## Common Operations

```bash
# Start
cd /opt/grid/stacks/hersonbot && docker compose up -d

# Stop, preserving data
cd /opt/grid/stacks/hersonbot && docker compose down

# Rebuild API after source changes
cd /opt/grid/stacks/hersonbot && docker compose up --build hersonbot-api -d

# Run end-to-end smoke test
/opt/grid/repos/hersonbot/scripts/smoke-test.sh
```

See [RUNBOOK.md](RUNBOOK.md) before running destructive commands such as
`docker compose down -v` or restore operations.

## Validation Commands

These checks are safe for repo hygiene changes:

```bash
# Bash: syntax-check tracked Python files without importing external services
python -m py_compile api/*.py

# Inspect docs and metadata changes
git diff -- README.md RUNBOOK.md .gitignore AGENTS.md .github/
```

PowerShell equivalent:

```powershell
python -m py_compile (Get-ChildItem api -Filter *.py).FullName
```

Full runtime validation requires the homelab Docker stack:

```bash
/opt/grid/repos/hersonbot/scripts/smoke-test.sh
```

## Roadmap

- Phase 2: LLM generation with Ollama or an OpenAI-compatible API
- Phase 3: Discord bot integration
- Phase 4: Web dashboard
- Phase 5: Agent memory and multi-model orchestration
