# HersonBot RAG Sandbox — Operational Runbook

Environment: `grid-node-01`<br>
Operator: `claudeops`<br>
Phase: `2E`<br>
Last updated: 2026-05-16

This runbook is the operator source of truth for running the HersonBot RAG Sandbox
on the Grid homelab host.

## Architecture

```text
operator / scripts
        |
        v
127.0.0.1:8100 -> hersonbot-api (FastAPI, Python 3.12)
                     |
                     v
               hersonbot_net
          isolated Docker bridge
                     |
                     v
              hersonbot-qdrant
              6333 HTTP, 6334 gRPC
                     |
                     v
        hersonbot_qdrant_storage Docker volume
```

The API reads source documents from the repo `docs/` directory mounted read-only
inside the container as `/docs`.

### Windows Ollama integration

LLM generation for `/answer` runs on a separate Windows PC rather than
on grid-node-01. The hardware split is intentional:

| Host | Role | Hardware |
| --- | --- | --- |
| `grid-node-01` | RAG orchestration, embeddings, retrieval | Intel i5-6th gen, 8 GB RAM, no GPU |
| `Dustins-PC` | Ollama LLM inference server | Intel i9-12900K, RTX 5070 |

**Confirmed network topology (verified 2026-05-16):**

- `Dustins-PC` LAN IP: `192.168.0.100`
- `Dustins-PC` Tailscale IP: `100.90.14.127`
- Tailscale peer path: direct (not relayed), 1 ms RTT
- grid-node-01 Tailscale IP: `100.67.140.117`

**Recommended connection path:** Tailscale (`100.90.14.127:11434`).
LAN IP is DHCP and may change; Tailscale IP is stable.

**Models available on Dustins-PC** (models stored in `D:\ollama\`):

| Model | Size | Notes |
| --- | --- | --- |
| `llama3:latest` | 4.7 GB | Active default — general-purpose |
| `mistral:latest` | 4.4 GB | Strong instruction following, faster than llama3 |
| `qwen2.5:latest` | 4.7 GB | Multilingual, strong reasoning |
| `qwen2.5-coder:14b` | 9.0 GB | Code-focused, largest model |
| `phi3:latest` | 2.2 GB | Smallest/fastest, good for low-latency use |

To switch models, update `OLLAMA_MODEL` in `/opt/grid/stacks/hersonbot/.env`
and run `docker compose up -d` (no rebuild needed).

**Current status (Phase 2E — confirmed 2026-05-16):** Fully operational.
`/answer` returns grounded LLM responses via `llama3` on the RTX 5070.
Typical latency: ~1.3 s retrieval, ~31 s generation (first token on cold model).

## Component Responsibilities

| Component | Image / Source | Role |
| --- | --- | --- |
| `hersonbot-api` | Built from `repos/hersonbot/api/` | Ingestion, chunking, embedding, retrieval |
| `hersonbot-qdrant` | `qdrant/qdrant:v1.14.1` | Persistent vector storage |
| `sentence-transformers` | `all-MiniLM-L6-v2` | Local 384-dimension embeddings |
| `Ollama` (remote) | Windows PC — not on grid-node-01 | LLM inference for `/answer` |

## Data Flow

Ingest:

```text
file/text -> chunk_text() -> embedder.embed() -> Qdrant upsert
```

Query:

```text
query text -> embedder.embed_one() -> Qdrant search -> top-k chunks and scores
```

## File Locations

| Path | Purpose |
| --- | --- |
| `/opt/grid/repos/hersonbot/` | Source checkout (git-tracked) |
| `/opt/grid/repos/hersonbot/api/` | FastAPI application |
| `/opt/grid/repos/hersonbot/docs/` | Documents available for file ingest |
| `/opt/grid/repos/hersonbot/scripts/` | Operational scripts |
| `/opt/grid/repos/hersonbot/deploy/docker-compose.example.yml` | **Version-controlled compose template** (see below) |
| `/opt/grid/stacks/hersonbot/` | Docker Compose stack directory (not git-tracked) |
| `/opt/grid/stacks/hersonbot/docker-compose.yml` | **Live compose file** — active runtime config |
| `/opt/grid/stacks/hersonbot/.env` | Active runtime environment (never commit) |
| `/opt/grid/backups/hersonbot/` | Qdrant backup archives |

### Compose file: live vs. template

The live compose file at `/opt/grid/stacks/hersonbot/docker-compose.yml` is the
active runtime configuration. It is **not tracked in git** because the stack
directory sits outside the repo and may contain environment-specific values.

A version-controlled reference template is maintained at:

```
deploy/docker-compose.example.yml
```

This template mirrors the live file structure and is kept in sync manually when
the stack configuration changes. Its purpose is:

- **Disaster recovery**: reconstruct the stack from scratch if the stack
  directory is lost.
- **Version control audit trail**: track structural changes to the compose
  config (healthchecks, service graph, port bindings) alongside the code that
  depends on them.
- **Onboarding reference**: new operators can read the template to understand
  the full stack without access to the live host.

To deploy from the template:

```bash
cp /opt/grid/repos/hersonbot/deploy/docker-compose.example.yml \
   /opt/grid/stacks/hersonbot/docker-compose.yml
cp /opt/grid/repos/hersonbot/.env.example \
   /opt/grid/stacks/hersonbot/.env
# Edit .env with real values, then:
cd /opt/grid/stacks/hersonbot && docker compose up -d
```

**Keep these two files in sync** whenever the live compose config changes.

## Service Ports

All ports must remain bound to `127.0.0.1`.

| Service | Host port | Container port | Protocol |
| --- | --- | --- | --- |
| HersonBot RAG Sandbox API | `127.0.0.1:8100` | `8100` | HTTP |
| Qdrant REST | `127.0.0.1:6333` | `6333` | HTTP |
| Qdrant gRPC | `127.0.0.1:6334` | `6334` | gRPC |

Existing homelab ports to avoid:

| Service | Port |
| --- | --- |
| Uptime Kuma | `3001` |
| Portainer | `8000`, `9000`, `9443` |
| Home Assistant | No exposed port documented here |

## Start, Stop, Rebuild

All compose commands must run from `/opt/grid/stacks/hersonbot` or use the
explicit `-f /opt/grid/stacks/hersonbot/docker-compose.yml` flag.

```bash
# Start all services
cd /opt/grid/stacks/hersonbot && docker compose up -d

# Stop all services, preserving data
cd /opt/grid/stacks/hersonbot && docker compose down

# Start Qdrant only for restore operations
cd /opt/grid/stacks/hersonbot && docker compose up qdrant -d

# Restart one service
cd /opt/grid/stacks/hersonbot && docker compose restart hersonbot-api
cd /opt/grid/stacks/hersonbot && docker compose restart qdrant

# Rebuild API image after source changes
cd /opt/grid/stacks/hersonbot && docker compose up --build hersonbot-api -d

# Check service status
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml ps
```

The Qdrant image is pinned upstream and does not need rebuilding for API source
changes.

## Docker Healthchecks (Phase 2D)

Both services have Docker Compose healthchecks. Docker probes them on a schedule
and marks each container `healthy`, `unhealthy`, or `starting`.

| Service | Command | Interval | Timeout | Retries | Start period |
| --- | --- | --- | --- | --- | --- |
| `hersonbot-qdrant` | `bash /dev/tcp` → `/healthz` | 30 s | 5 s | 3 | 20 s |
| `hersonbot-api` | `python3 urllib` → `/health` | 30 s | 10 s | 3 | 30 s |

`bash /dev/tcp` is used for Qdrant because the upstream image has no `curl` or
`wget`. `python3` stdlib is used for the API for the same reason.

The `hersonbot-api` `depends_on` is upgraded to `condition: service_healthy`,
so Compose will not start the API until Qdrant reports healthy.

### Check healthcheck status

```bash
docker inspect --format '{{.State.Health.Status}}' hersonbot-api
docker inspect --format '{{.State.Health.Status}}' hersonbot-qdrant

# Or in one line via compose ps
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml ps
```

Expected output: `healthy` for both.

### View healthcheck history (last 5 results)

```bash
docker inspect --format '{{json .State.Health}}' hersonbot-api | python3 -m json.tool
docker inspect --format '{{json .State.Health}}' hersonbot-qdrant | python3 -m json.tool
```

### Troubleshoot an unhealthy container

1. Check recent healthcheck output:

   ```bash
   docker inspect --format '{{range .State.Health.Log}}{{.ExitCode}} {{.Output}}{{end}}' hersonbot-api
   ```

2. Run the healthcheck manually inside the container:

   ```bash
   # API
   docker exec hersonbot-api python3 -c \
     "import urllib.request, sys; r = urllib.request.urlopen('http://127.0.0.1:8100/health', timeout=5); sys.exit(0 if r.status == 200 else 1)"

   # Qdrant
   docker exec hersonbot-qdrant bash -c \
     "exec 3<>/dev/tcp/127.0.0.1/6333 && printf 'GET /healthz HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' >&3 && grep -q 'passed' <&3"
   ```

3. Check service logs:

   ```bash
   docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs --tail=50 hersonbot-api
   docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs --tail=50 qdrant
   ```

4. Restart the affected service (preserves data):

   ```bash
   docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml restart hersonbot-api
   ```

## Health Checks

```bash
curl -s http://127.0.0.1:8100/health
curl -s http://127.0.0.1:6333/healthz
curl -s http://127.0.0.1:8100/collections
```

Expected API health response:

```json
{"status":"ok"}
```

## Ingest Commands

Documents for file ingest must be `.txt` files under
`/opt/grid/repos/hersonbot/docs/`.

```bash
# Ingest a file
curl -s -X POST http://127.0.0.1:8100/ingest/file \
  -H "Content-Type: application/json" \
  -d '{"path": "sample.txt"}'

# Ingest raw text
curl -s -X POST http://127.0.0.1:8100/ingest/text \
  -H "Content-Type: application/json" \
  -d '{"doc_id": "my-note", "text": "Your content here."}'

# Ingest every .txt file in docs/
for f in /opt/grid/repos/hersonbot/docs/*.txt; do
  filename=$(basename "$f")
  curl -s -X POST http://127.0.0.1:8100/ingest/file \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"${filename}\"}"
  echo
done
```

### Delete All Chunks For A Document

```bash
curl -s -X DELETE http://127.0.0.1:8100/ingest/{doc_id}
```

Example:

```bash
curl -s -X DELETE http://127.0.0.1:8100/ingest/my-note
# → {"status":"deleted","doc_id":"my-note"}
```

The endpoint deletes every Qdrant point whose `doc_id` payload field matches the
given value. Deleting a non-existent `doc_id` is safe and returns the same
response.

### Delete-Before-Reingest Workflow

Use this when updating a document that may have shrunk (fewer chunks than before).
Without deleting first, orphaned chunks from the old version remain in Qdrant.

```bash
# 1. Remove old chunks
curl -s -X DELETE http://127.0.0.1:8100/ingest/my-document

# 2. Re-ingest the updated file
curl -s -X POST http://127.0.0.1:8100/ingest/file \
  -H "Content-Type: application/json" \
  -d '{"path": "my-document.txt"}'
```

This is also the recommended pattern for fully removing a document from the
knowledge base.

## Answer Generation (Phase 2C)

`POST /answer` retrieves context chunks and passes them to a local Ollama model to
produce a grounded answer. The endpoint is disabled (returns 503) when `OLLAMA_HOST`
is not set in the stack `.env`.

**Architecture note:** Ollama runs on `Dustins-PC` (RTX 5070), not on
grid-node-01. The API container reaches it over Tailscale. Do not install Ollama
on grid-node-01.

### Enabling Windows Ollama

Ollama on Windows defaults to binding only on `127.0.0.1:11434`, which makes it
unreachable from other machines even over Tailscale. Two changes are required on
the Windows side.

#### Step 1 — Configure Ollama to accept external connections (Windows)

Set the environment variable for the Ollama process. Choose one method:

**Option A — System-wide via Windows environment variables (recommended, survives restarts):**

1. Open **System Properties → Advanced → Environment Variables**
2. Under **System variables**, click **New**:
   - Variable name: `OLLAMA_HOST`
   - Variable value: `0.0.0.0:11434`
3. Click OK
4. **Restart the Ollama service** (Task Manager → Services → find Ollama → Restart,
   or restart the Ollama app from system tray)

**Option B — Per-session in PowerShell (for testing only):**

```powershell
$env:OLLAMA_HOST = "0.0.0.0:11434"
ollama serve
```

#### Step 2 — Allow TCP 11434 in Windows Defender Firewall (Windows)

Run in an **elevated PowerShell** (Run as Administrator):

```powershell
New-NetFirewallRule `
  -DisplayName "Ollama API (Tailscale)" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 11434 `
  -Action Allow `
  -Profile Any
```

Or via GUI: Windows Defender Firewall → Advanced Settings → Inbound Rules →
New Rule → Port → TCP 11434 → Allow → All profiles → Name: "Ollama API".

#### Step 3 — Pull the model (Windows)

```powershell
ollama pull llama3
```

#### Step 4 — Verify from grid-node-01

After applying the above, test from grid-node-01:

```bash
# From the host
python3 -c "
import urllib.request
r = urllib.request.urlopen('http://100.90.14.127:11434/api/tags', timeout=5)
print(r.read().decode())
"

# From inside the container
docker exec hersonbot-api python3 -c "
import urllib.request
r = urllib.request.urlopen('http://100.90.14.127:11434/api/tags', timeout=5)
print(r.read().decode())
"
```

Expected: JSON listing available models (e.g. `{"models":[{"name":"llama3",...}]}`).

### Active configuration (Phase 2E)

Live `.env` values at `/opt/grid/stacks/hersonbot/.env`:

```
OLLAMA_HOST=http://100.90.14.127:11434
OLLAMA_MODEL=llama3
OLLAMA_TIMEOUT_SECONDS=60
OLLAMA_CONTEXT_TOP_K=5
```

**Design notes:**
- Tailscale IP (`100.90.14.127`) used — stable, survives LAN IP changes.
- LAN IP (`192.168.0.100`) is DHCP-assigned; do not use it in config.
- No `extra_hosts` required — the container reaches Tailscale IPs through the
  Docker bridge → host kernel → `tailscale0` interface natively.
- `host.docker.internal` is not needed; that pattern is only for reaching the
  Docker host itself, not a remote Tailscale peer.

### To reconfigure or restore

If the `.env` is lost or Ollama moves to a new IP:

```bash
# Edit env
nano /opt/grid/stacks/hersonbot/.env

# Restart API (no rebuild required)
cd /opt/grid/stacks/hersonbot && docker compose up -d

# Verify
curl -s -X POST http://127.0.0.1:8100/answer \
  -H "Content-Type: application/json" \
  -d '{"query": "what is HersonBot RAG Sandbox"}' \
  | python3 -m json.tool
```

### To disable Ollama (revert to retrieval-only mode)

```bash
# Remove or comment OLLAMA_HOST in /opt/grid/stacks/hersonbot/.env
# Then restart:
cd /opt/grid/stacks/hersonbot && docker compose up -d
# /answer will return 503 ollama_unconfigured; /query continues to work normally
```

### Answer Query

```bash
curl -s -X POST http://127.0.0.1:8100/answer \
  -H "Content-Type: application/json" \
  -d '{"query": "what is HersonBot RAG Sandbox"}' \
  | python3 -m json.tool
```

Response fields:

| Field | Meaning |
| --- | --- |
| `answer` | LLM-generated answer grounded in retrieved context |
| `model` | Ollama model name used |
| `sources` | List of chunks with index, doc_id, chunk_index, score |
| `retrieval_ms` | Time spent on vector retrieval |
| `generation_ms` | Time spent on LLM generation |

Error codes returned in `{"error": {"code": "...", "detail": "..."}}`:

| HTTP | Code | Cause |
| --- | --- | --- |
| 503 | `ollama_unconfigured` | `OLLAMA_HOST` not set |
| 502 | `ollama_unreachable` | Cannot connect to Ollama |
| 504 | `ollama_timeout` | Ollama did not respond in time |
| 502 | `ollama_model_missing` | Model not pulled on Ollama host |
| 502 | `ollama_invalid_response` | Unexpected Ollama response |

## Query Commands

```bash
# Basic query
curl -s -X POST http://127.0.0.1:8100/query \
  -H "Content-Type: application/json" \
  -d '{"query": "what is HersonBot RAG Sandbox", "top_k": 3}' \
  | python3 -m json.tool

# Query with a larger result set
curl -s -X POST http://127.0.0.1:8100/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Grid homelab architecture", "top_k": 5}'
```

Result fields:

| Field | Meaning |
| --- | --- |
| `score` | Cosine similarity; higher means more relevant |
| `doc_id` | Source document identifier |
| `chunk_index` | Chunk position in the source document |
| `text` | Chunk content |

Scores below about `0.35` are usually low-signal.

Interactive API docs are available at:

```text
http://127.0.0.1:8100/docs
```

## Logs And Debug

```bash
# Tail all logs
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs -f

# Tail one service
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs -f hersonbot-api
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs -f qdrant

# Last 100 log lines
docker compose -f /opt/grid/stacks/hersonbot/docker-compose.yml logs --tail=100

# Inspect container resource usage
docker stats hersonbot-api hersonbot-qdrant --no-stream

# Inspect API container
docker exec -it hersonbot-api /bin/bash

# Inspect Qdrant container
docker exec -it hersonbot-qdrant /bin/bash
```

## Smoke Test

Run the smoke test after startup, restore, or API rebuild:

```bash
/opt/grid/repos/hersonbot/scripts/smoke-test.sh
```

The smoke test checks container status, homelab safety assumptions, health
endpoints, collection availability, text ingest, retrieval, localhost-only port
bindings, deduplication behavior, and delete-by-doc_id correctness.

## Backup And Restore

Backups are tar.gz archives of the `hersonbot_qdrant_storage` Docker volume.
They are stored in `/opt/grid/backups/hersonbot/`.

Qdrant does not need to be stopped for backup. Qdrant must be stopped before
restore, which the restore script handles.

```bash
# Backup
/opt/grid/repos/hersonbot/scripts/backup-qdrant.sh

# Restore
/opt/grid/repos/hersonbot/scripts/restore-qdrant.sh /opt/grid/backups/hersonbot/qdrant-20260515-143022.tar.gz

# List backups
ls -lh /opt/grid/backups/hersonbot/
```

Manual backup:

```bash
mkdir -p /opt/grid/backups/hersonbot
docker run --rm \
  -v hersonbot_qdrant_storage:/source:ro \
  -v /opt/grid/backups/hersonbot:/backup \
  alpine \
  tar -czf /backup/qdrant-$(date +%Y%m%d-%H%M%S).tar.gz -C /source .
```

## Full Cleanup

```bash
# Stop services only
cd /opt/grid/stacks/hersonbot && docker compose down

# Remove containers and network, keeping image and volume data
cd /opt/grid/stacks/hersonbot && docker compose down --remove-orphans

# Remove containers, network, and all vector data
cd /opt/grid/stacks/hersonbot && docker compose down -v

# Remove the built API image
docker rmi hersonbot-hersonbot-api

# Remove the Qdrant image
docker rmi qdrant/qdrant:v1.14.1
```

`docker compose down -v` permanently deletes the
`hersonbot_qdrant_storage` volume. Back up first if the data matters.

Source files in `/opt/grid/repos/hersonbot/` are not removed by these commands.

## Safety Boundaries

These boundaries are part of the system design and should not be changed during
routine maintenance.

| Boundary | Status |
| --- | --- |
| Ports bind to `127.0.0.1` | Required |
| No Docker host network mode | Required |
| No privileged containers | Required |
| No broad host mounts | Required; only `docs/` read-only plus named volume |
| No sudo required | Required for normal operations |
| Home Assistant untouched | Separate container, no shared volumes or networks |
| Uptime Kuma untouched | Separate container, no shared volumes or networks |
| Portainer untouched | Separate container, no shared volumes or networks |
| Qdrant data isolated | Named volume `hersonbot_qdrant_storage` |
| Network isolation | Separate `hersonbot_net` bridge |

This system intentionally cannot:

- Reach the internet as part of the current retrieval flow.
- Write to the host filesystem except through backup scripts writing to
  `/opt/grid/backups/`.
- Modify Docker daemon configuration.
- Modify SSH, firewall, or system packages.

## Known Limitations

| Limitation | Impact | Future resolution |
| --- | --- | --- |
| Plain text only for `/ingest/file` | PDFs, Markdown, and HTML cannot be ingested directly | Add document loaders |
| ~~Orphaned chunks on document shrink~~ | **Resolved in Phase 2B.** Use `DELETE /ingest/{doc_id}` before re-ingesting updated documents. | — |
| Pre-2A duplicate data | Older random-UUID chunks may still exist if the collection was not reset after Phase 2A | One-time `docker compose down -v` and re-ingest |
| ~~No LLM generation~~ | **Resolved in Phase 2C.** `/answer` adds optional Ollama-backed generation. `/query` still returns raw chunks. | — |
| No authentication | Any local process can call the API | Add token auth when access broadens |
| Fixed chunk size | Prose works better than code or tables | Add per-document chunking strategy |
| No ingest manifest | No easy list of ingested documents | Add manifest or collection inspection endpoint |
| Embedding model fixed at build time | Model changes require image rebuild | Acceptable for current phase |
| Volume-level backup only | No per-document restore | Acceptable for current phase |
| ~~No Compose healthcheck documented in repo~~ | **Resolved in Phase 2D.** Both services have `healthcheck` blocks; `hersonbot-api` `depends_on` upgraded to `condition: service_healthy`. | — |
