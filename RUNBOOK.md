# HersonBot RAG — Operational Runbook

**Environment:** grid-node-01 · Operator: claudeops · Phase: 2A  
**Last updated:** 2026-05-15

---

## Table of Contents

1. [Architecture](#architecture)
2. [Service Ports](#service-ports)
3. [Start / Stop / Rebuild](#start--stop--rebuild)
4. [Ingest Commands](#ingest-commands)
5. [Query Commands](#query-commands)
6. [Logs and Debug](#logs-and-debug)
7. [Backup and Restore](#backup-and-restore)
8. [Full Cleanup](#full-cleanup)
9. [Safety Boundaries](#safety-boundaries)
10. [Known Limitations](#known-limitations)

---

## Architecture

```
  operator / scripts
        │
        ▼
  127.0.0.1:8100  ──►  hersonbot-api  (FastAPI, Python 3.12)
                              │
                    ┌─────────▼──────────────────────────┐
                    │          hersonbot_net              │
                    │   (isolated Docker bridge network)  │
                    │                                     │
                    │  hersonbot-api ──► hersonbot-qdrant │
                    │                   :6333 (HTTP)      │
                    │                   :6334 (gRPC)      │
                    └─────────────────────────────────────┘
                              │
                    ┌─────────▼──────────────────────┐
                    │  Docker volumes                 │
                    │  hersonbot_qdrant_storage       │  ← vector data
                    │                                 │
                    │  Bind mount (read-only)         │
                    │  /opt/grid/repos/hersonbot/docs │  → /docs inside API
                    └─────────────────────────────────┘
```

### Component responsibilities

| Component | Image / Source | Role |
|-----------|---------------|------|
| `hersonbot-api` | Built from `repos/hersonbot/api/` | Ingestion, chunking, embedding, retrieval |
| `hersonbot-qdrant` | `qdrant/qdrant:v1.14.1` | Persistent vector storage |
| sentence-transformers | `all-MiniLM-L6-v2` (384-dim) | Local embedding model, baked into image |

### Data flow — ingest

```
File / text  →  chunk_text()  →  embedder.embed()  →  Qdrant upsert
              (500 chars,       (all-MiniLM-L6-v2,    (cosine distance,
               50 overlap)       normalized)            hersonbot collection)
```

### Data flow — query

```
Query string  →  embedder.embed_one()  →  Qdrant search  →  top-k chunks + scores
```

### File locations

| Path | Purpose |
|------|---------|
| `/opt/grid/repos/hersonbot/` | Source code |
| `/opt/grid/repos/hersonbot/api/` | FastAPI application |
| `/opt/grid/repos/hersonbot/docs/` | Documents available for ingestion |
| `/opt/grid/repos/hersonbot/scripts/` | Operational scripts |
| `/opt/grid/stacks/hersonbot/` | Docker Compose stack definition |
| `/opt/grid/stacks/hersonbot/.env` | Active environment variables |
| `/opt/grid/backups/hersonbot/` | Qdrant snapshot tarballs |

---

## Service Ports

All ports are bound to `127.0.0.1`. Nothing is reachable from the network.

| Service | Host port | Container port | Protocol |
|---------|-----------|----------------|----------|
| HersonBot API | `127.0.0.1:8100` | 8100 | HTTP |
| Qdrant REST | `127.0.0.1:6333` | 6333 | HTTP |
| Qdrant gRPC | `127.0.0.1:6334` | 6334 | gRPC |

### Existing homelab ports (do not conflict with)

| Service | Port |
|---------|------|
| Uptime Kuma | 3001 |
| Portainer | 8000, 9000, 9443 |
| Home Assistant | (no exposed port) |

---

## Start / Stop / Rebuild

All compose commands must be run from the stack directory or use the `-f` flag.

```bash
STACK=/opt/grid/stacks/hersonbot
```

### Start all services

```bash
cd /opt/grid/stacks/hersonbot && docker compose up -d
```

### Stop all services (data preserved)

```bash
cd /opt/grid/stacks/hersonbot && docker compose down
```

### Start Qdrant only (e.g. for restore operations)

```bash
cd /opt/grid/stacks/hersonbot && docker compose up qdrant -d
```

### Restart a single service

```bash
cd /opt/grid/stacks/hersonbot && docker compose restart hersonbot-api
cd /opt/grid/stacks/hersonbot && docker compose restart qdrant
```

### Rebuild the API image after code changes

```bash
cd /opt/grid/stacks/hersonbot && docker compose up --build hersonbot-api -d
```

> The Qdrant image does not need rebuilding — it is a pinned upstream image.

### Check service status

```bash
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml ps
```

---

## Ingest Commands

Documents must be `.txt` files placed in `/opt/grid/repos/hersonbot/docs/` before ingesting via the file endpoint.

### Ingest a file

```bash
curl -s -X POST http://127.0.0.1:8100/ingest/file \
  -H "Content-Type: application/json" \
  -d '{"path": "sample.txt"}'
```

Expected response:

```json
{"status":"ingested","file":"sample.txt","chunks":5}
```

### Ingest raw text

```bash
curl -s -X POST http://127.0.0.1:8100/ingest/text \
  -H "Content-Type: application/json" \
  -d '{"doc_id": "my-note", "text": "Your content here."}'
```

Expected response:

```json
{"status":"ingested","doc_id":"my-note","chunks":1}
```

### List collections

```bash
curl -s http://127.0.0.1:8100/collections
```

Expected response:

```json
{"collections":[{"name":"hersonbot"}]}
```

### Ingest multiple files (shell loop)

```bash
for f in /opt/grid/repos/hersonbot/docs/*.txt; do
  filename=$(basename "$f")
  curl -s -X POST http://127.0.0.1:8100/ingest/file \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"${filename}\"}"
  echo
done
```

---

## Query Commands

### Basic query

```bash
curl -s -X POST http://127.0.0.1:8100/query \
  -H "Content-Type: application/json" \
  -d '{"query": "what is HersonBot", "top_k": 3}' \
  | python3 -m json.tool
```

### Query with custom top_k

```bash
curl -s -X POST http://127.0.0.1:8100/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Grid homelab architecture", "top_k": 5}'
```

### Interpret results

Each result contains:

| Field | Meaning |
|-------|---------|
| `score` | Cosine similarity (0–1). Higher = more relevant. |
| `doc_id` | Source document identifier |
| `chunk_index` | Position of this chunk within the source doc |
| `text` | Chunk content |

Scores below ~0.35 are typically low-signal.

### Interactive API docs

```
http://127.0.0.1:8100/docs
```

---

## Logs and Debug

### Tail all logs

```bash
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs -f
```

### Tail a single service

```bash
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs -f hersonbot-api
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs -f qdrant
```

### Last 100 lines

```bash
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs --tail=100
```

### Check Qdrant health directly

```bash
curl -s http://127.0.0.1:6333/healthz
# → healthz check passed

curl -s http://127.0.0.1:6333/collections
# → {"result":{"collections":[{"name":"hersonbot"}]},"status":"ok","time":...}
```

### Check API health

```bash
curl -s http://127.0.0.1:8100/health
# → {"status":"ok"}
```

### Inspect container resource usage

```bash
docker stats hersonbot-api hersonbot-qdrant --no-stream
```

### Exec into API container (read-only inspection)

```bash
docker exec -it hersonbot-api /bin/bash
```

### Exec into Qdrant container

```bash
docker exec -it hersonbot-qdrant /bin/bash
```

### Smoke test (automated)

```bash
/opt/grid/repos/hersonbot/scripts/smoke-test.sh
```

---

## Backup and Restore

Backups are tar.gz snapshots of the `hersonbot_qdrant_storage` Docker volume. They are stored in `/opt/grid/backups/hersonbot/`. No external tools or sudo required.

> **Note:** Qdrant must be stopped before restoring to avoid data corruption. It does not need to be stopped for backup (the snapshot is taken from a running volume, which is safe for Qdrant's append-friendly storage format).

### Backup

```bash
/opt/grid/repos/hersonbot/scripts/backup-qdrant.sh
```

The script creates a timestamped file:

```
/opt/grid/backups/hersonbot/qdrant-20260515-143022.tar.gz
```

### Restore

```bash
/opt/grid/repos/hersonbot/scripts/restore-qdrant.sh /opt/grid/backups/hersonbot/qdrant-20260515-143022.tar.gz
```

The script stops the full stack, wipes the existing volume, restores from the archive, and restarts.

### Manual backup (without script)

```bash
mkdir -p /opt/grid/backups/hersonbot
docker run --rm \
  -v hersonbot_qdrant_storage:/source:ro \
  -v /opt/grid/backups/hersonbot:/backup \
  alpine \
  tar -czf /backup/qdrant-$(date +%Y%m%d-%H%M%S).tar.gz -C /source .
```

### List backups

```bash
ls -lh /opt/grid/backups/hersonbot/
```

---

## Full Cleanup

### Stop services only (keep images, volumes, data)

```bash
cd /opt/grid/stacks/hersonbot && docker compose down
```

### Remove containers and network (keep images and volume data)

```bash
cd /opt/grid/stacks/hersonbot && docker compose down --remove-orphans
```

### Remove containers, network, and all vector data

```bash
cd /opt/grid/stacks/hersonbot && docker compose down -v
```

> This permanently deletes the `hersonbot_qdrant_storage` volume. Back up first if needed.

### Remove the built API image

```bash
docker rmi hersonbot-hersonbot-api
```

### Remove the Qdrant image

```bash
docker rmi qdrant/qdrant:v1.14.1
```

### Full teardown (everything except source files)

```bash
cd /opt/grid/stacks/hersonbot
docker compose down -v
docker rmi hersonbot-hersonbot-api
```

Source files in `/opt/grid/repos/hersonbot/` are never touched by any of the above commands.

---

## Safety Boundaries

These boundaries are enforced by design and must not be violated.

| Boundary | Status |
|----------|--------|
| All ports bound to `127.0.0.1` | Enforced in `docker-compose.yml` |
| No `host` network mode | Confirmed — bridge network only |
| No privileged containers | Confirmed — no `privileged: true` |
| No broad host mounts | Only `docs/` (read-only) and named volume |
| No sudo required for any operation | Confirmed — claudeops has Docker access |
| Home Assistant untouched | Separate container, no shared volumes/networks |
| Uptime Kuma untouched | Separate container, no shared volumes/networks |
| Portainer untouched | Separate container, no shared volumes/networks |
| Qdrant data isolated | Named volume `hersonbot_qdrant_storage`, not shared |
| Network isolation | `hersonbot_net` bridge is separate from all other Docker networks |

### What this system intentionally cannot do

- It cannot reach the internet (no outbound routing needed; embeddings are local)
- It cannot write to the host filesystem except via the backup scripts writing to `/opt/grid/backups/`
- It cannot modify Docker daemon configuration
- It cannot modify SSH, firewall, or system packages

---

## Known Limitations

| Limitation | Impact | Future resolution |
|------------|--------|-------------------|
| Plain text only (`/ingest/file`) | PDFs, markdown, HTML cannot be ingested directly | Phase 2: add document loaders |
| ~~No deduplication on re-ingest~~ | **Resolved in Phase 2A.** Chunk IDs are now deterministic (SHA-256 of `doc_id:chunk_index`). Re-ingesting the same file upserts over existing points — no new duplicates are created. | — |
| Orphaned chunks on document shrink | If a document is re-ingested with fewer chunks than before, the old higher-index chunk IDs remain in Qdrant as orphans (they are not queried for unrelated topics, but they occupy space). | Phase 2B: delete-by-doc_id before re-ingest |
| Pre-2A duplicate data requires manual migration | Any data ingested before Phase 2A used random UUIDs and may contain duplicates. Run `docker compose down -v && docker compose up -d` then re-ingest all documents to get a clean state. | One-time operator action |
| No LLM generation | `/query` returns raw chunks, not synthesized answers | Phase 2: Ollama / OpenAI generation |
| No authentication | API is open to any local process | Acceptable for localhost-only; Phase 3: token auth |
| Chunk size is fixed globally | 500 chars / 50 overlap suits prose; poor for code or tables | Phase 2: per-doc chunking strategy |
| No ingest status tracking | No way to list what has been ingested other than Qdrant payload inspection | Phase 2: ingest manifest |
| Embedding model fixed at build time | Changing models requires a full image rebuild | Acceptable for Phase 1 |
| Qdrant backup is volume-level | No per-collection or per-document granularity | Acceptable for Phase 1 |
| No health-check in compose | Docker cannot auto-restart on hung API | Phase 2: add `healthcheck:` block |
| `/docs` bind mount is read-only | Files must be placed there by the operator manually | Acceptable; upload endpoint is Phase 2 |
