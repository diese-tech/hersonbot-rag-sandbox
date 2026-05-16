# HersonBot — Local RAG Sandbox

A self-contained, local-first RAG (Retrieval-Augmented Generation) system for the Grid homelab. Ingest documents, query them semantically — no cloud APIs required.

> **Operators:** see [RUNBOOK.md](RUNBOOK.md) for the full operational guide — architecture, backup/restore, debug commands, safety boundaries, and known limitations.

## Stack

| Component | Role |
|-----------|------|
| Qdrant | Vector database |
| FastAPI | Ingestion + retrieval API |
| sentence-transformers (all-MiniLM-L6-v2) | Local embeddings |
| Docker Compose | All service orchestration |

All services bind to `127.0.0.1` only. Nothing is exposed to the network.

---

## Quickstart

```bash
# 1. Copy env template (first time only)
cp /opt/grid/repos/hersonbot/.env.example /opt/grid/stacks/hersonbot/.env

# 2. Start everything
cd /opt/grid/stacks/hersonbot
docker compose up -d

# 3. Check health
curl http://127.0.0.1:8100/health
# → {"status":"ok"}

curl http://127.0.0.1:6333/healthz
# → {"title":"qdrant - version ..."}
```

---

## Ingest a document

### From a file (must be in /opt/grid/repos/hersonbot/docs/)

```bash
curl -X POST http://127.0.0.1:8100/ingest/file \
  -H "Content-Type: application/json" \
  -d '{"path": "sample.txt"}'
# → {"status":"ingested","file":"sample.txt","chunks":7}
```

### From raw text

```bash
curl -X POST http://127.0.0.1:8100/ingest/text \
  -H "Content-Type: application/json" \
  -d '{"doc_id": "my-note", "text": "HersonBot lives on grid-node-01."}'
# → {"status":"ingested","doc_id":"my-note","chunks":1}
```

---

## Query the knowledge base

```bash
curl -X POST http://127.0.0.1:8100/query \
  -H "Content-Type: application/json" \
  -d '{"query": "what is HersonBot", "top_k": 3}'
```

Returns top-k chunks ranked by cosine similarity with their source doc and score.

---

## Interactive API docs

```
http://127.0.0.1:8100/docs
```

---

## Lifecycle commands

```bash
# Start
cd /opt/grid/stacks/hersonbot && docker compose up -d

# Stop (data preserved)
cd /opt/grid/stacks/hersonbot && docker compose down

# Full reset (wipes vector data)
cd /opt/grid/stacks/hersonbot && docker compose down -v

# View logs
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs -f

# Rebuild API after code changes
cd /opt/grid/stacks/hersonbot && docker compose up --build hersonbot-api -d
```

---

## Adding documents

Drop any `.txt` file into `/opt/grid/repos/hersonbot/docs/` and call `/ingest/file` with the filename. More formats (PDF, Markdown, HTML) are planned for a future phase.

---

## Ports

| Service | Port |
|---------|------|
| HersonBot API | 127.0.0.1:8100 |
| Qdrant HTTP | 127.0.0.1:6333 |
| Qdrant gRPC | 127.0.0.1:6334 |

---

## Roadmap

- [ ] Phase 2: LLM generation (Ollama / OpenAI-compatible)
- [ ] Phase 3: Discord bot integration
- [ ] Phase 4: Web dashboard
- [ ] Phase 5: Agent memory + multi-model orchestration
