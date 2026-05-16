#!/usr/bin/env bash
# smoke-test.sh — end-to-end health and functional verification for HersonBot RAG Sandbox
# Exits 0 on full pass, 1 on any failure.
# No sudo required. Safe to run at any time against the live stack.

set -euo pipefail

API="http://127.0.0.1:8100"
QDRANT="http://127.0.0.1:6333"
SMOKE_DOC_ID="smoke-test-$(date +%s)"
PASS=0
FAIL=0

green()  { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m✗ %s\033[0m\n' "$*"; }
header() { printf '\n\033[1m%s\033[0m\n' "$*"; }

check() {
  local label="$1"
  local result="$2"
  local expected="$3"
  if echo "$result" | grep -q "$expected"; then
    green "$label"
    PASS=$((PASS + 1))
  else
    red "$label"
    echo "  Expected to contain: ${expected}"
    echo "  Got: ${result}"
    FAIL=$((FAIL + 1))
  fi
}

# ── 1. Container status ───────────────────────────────────────────────────────

header "1. Container status"

API_STATUS=$(docker inspect --format '{{.State.Status}}' hersonbot-api 2>/dev/null || echo "missing")
QDRANT_STATUS=$(docker inspect --format '{{.State.Status}}' hersonbot-qdrant 2>/dev/null || echo "missing")

check "hersonbot-api container is running" "$API_STATUS" "running"
check "hersonbot-qdrant container is running" "$QDRANT_STATUS" "running"

API_HEALTH=$(docker inspect --format '{{.State.Health.Status}}' hersonbot-api 2>/dev/null || echo "no-healthcheck")
QDRANT_HEALTH=$(docker inspect --format '{{.State.Health.Status}}' hersonbot-qdrant 2>/dev/null || echo "no-healthcheck")

check "hersonbot-api Docker health is healthy" "$API_HEALTH" "healthy"
check "hersonbot-qdrant Docker health is healthy" "$QDRANT_HEALTH" "healthy"

# ── 2. Existing homelab containers untouched ──────────────────────────────────

header "2. Homelab containers untouched"

HA_STATUS=$(docker inspect --format '{{.State.Status}}' homeassistant 2>/dev/null || echo "missing")
UK_STATUS=$(docker inspect --format '{{.State.Status}}' uptime-kuma 2>/dev/null || echo "missing")
PT_STATUS=$(docker inspect --format '{{.State.Status}}' portainer 2>/dev/null || echo "missing")

check "homeassistant is running" "$HA_STATUS" "running"
check "uptime-kuma is running" "$UK_STATUS" "running"
check "portainer is running" "$PT_STATUS" "running"

# ── 3. Health endpoints ───────────────────────────────────────────────────────

header "3. Health endpoints"

API_HEALTH=$(curl -sf --max-time 5 "${API}/health" 2>/dev/null || echo "UNREACHABLE")
QDRANT_HEALTH=$(curl -sf --max-time 5 "${QDRANT}/healthz" 2>/dev/null || echo "UNREACHABLE")

check "API /health returns ok" "$API_HEALTH" "ok"
check "Qdrant /healthz passes" "$QDRANT_HEALTH" "passed"

# ── 4. Qdrant collection exists ───────────────────────────────────────────────

header "4. Qdrant collection"

COLLECTIONS=$(curl -sf --max-time 5 "${API}/collections" 2>/dev/null || echo "UNREACHABLE")
check "hersonbot collection exists" "$COLLECTIONS" "hersonbot"

# ── 5. Ingest smoke document ──────────────────────────────────────────────────

header "5. Ingest"

INGEST_RESULT=$(curl -sf --max-time 15 -X POST "${API}/ingest/text" \
  -H "Content-Type: application/json" \
  -d "{\"doc_id\": \"${SMOKE_DOC_ID}\", \"text\": \"HersonBot RAG Sandbox smoke test document for grid-node-01 verification.\"}" \
  2>/dev/null || echo "UNREACHABLE")

check "Text ingest returns ingested status" "$INGEST_RESULT" "ingested"

# ── 6. Query retrieval ────────────────────────────────────────────────────────

header "6. Query retrieval"

# Small sleep to ensure the upsert is visible
sleep 1

QUERY_RESULT=$(curl -sf --max-time 15 -X POST "${API}/query" \
  -H "Content-Type: application/json" \
  -d '{"query": "smoke test grid-node-01", "top_k": 20}' \
  2>/dev/null || echo "UNREACHABLE")

check "Query returns results" "$QUERY_RESULT" "results"
check "Query result contains score field" "$QUERY_RESULT" "score"
check "Smoke doc appears in results" "$QUERY_RESULT" "$SMOKE_DOC_ID"

# ── 7. Port binding safety ────────────────────────────────────────────────────

header "7. Port binding (localhost-only)"

API_PORT_BIND=$(docker inspect hersonbot-api \
  --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostIp}}:{{.HostPort}}->{{$p}} {{end}}{{end}}' \
  2>/dev/null || echo "unknown")

QDRANT_PORT_BIND=$(docker inspect hersonbot-qdrant \
  --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostIp}}:{{.HostPort}}->{{$p}} {{end}}{{end}}' \
  2>/dev/null || echo "unknown")

check "API bound to 127.0.0.1 only" "$API_PORT_BIND" "127.0.0.1"
check "Qdrant bound to 127.0.0.1 only" "$QDRANT_PORT_BIND" "127.0.0.1"

# Check that 0.0.0.0 is NOT in the bindings
if echo "$API_PORT_BIND" | grep -q "0.0.0.0"; then
  red "API port is exposed on 0.0.0.0 — SAFETY VIOLATION"
  FAIL=$((FAIL + 1))
else
  green "API port not exposed on 0.0.0.0"
  PASS=$((PASS + 1))
fi

if echo "$QDRANT_PORT_BIND" | grep -q "0.0.0.0"; then
  red "Qdrant port is exposed on 0.0.0.0 — SAFETY VIOLATION"
  FAIL=$((FAIL + 1))
else
  green "Qdrant port not exposed on 0.0.0.0"
  PASS=$((PASS + 1))
fi

# ── 8. Deduplication ──────────────────────────────────────────────────────────

header "8. Deduplication (Phase 2A)"

DEDUP_DOC_ID="smoke-dedup-check"
DEDUP_TEXT="Deduplication verification text for HersonBot RAG Sandbox Phase 2A. Ingest this twice and expect one copy."

# Ingest the same doc_id twice in a row
curl -sf --max-time 15 -X POST "${API}/ingest/text" \
  -H "Content-Type: application/json" \
  -d "{\"doc_id\": \"${DEDUP_DOC_ID}\", \"text\": \"${DEDUP_TEXT}\"}" > /dev/null 2>&1

curl -sf --max-time 15 -X POST "${API}/ingest/text" \
  -H "Content-Type: application/json" \
  -d "{\"doc_id\": \"${DEDUP_DOC_ID}\", \"text\": \"${DEDUP_TEXT}\"}" > /dev/null 2>&1

sleep 1

DEDUP_QUERY=$(curl -sf --max-time 15 -X POST "${API}/query" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"deduplication verification Phase 2A\", \"top_k\": 20}" \
  2>/dev/null || echo "UNREACHABLE")

check "Dedup query returns results" "$DEDUP_QUERY" "results"

# Count duplicate (doc_id, chunk_index) pairs using python3
DUP_COUNT=$(echo "$DEDUP_QUERY" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('results', [])
    seen = set()
    dups = 0
    for r in results:
        key = (r.get('doc_id'), r.get('chunk_index'))
        if key in seen:
            dups += 1
        seen.add(key)
    print(dups)
except Exception:
    print(-1)
" 2>/dev/null)

if [ "$DUP_COUNT" = "0" ]; then
  green "No duplicate chunks after double ingest (dedup working)"
  PASS=$((PASS + 1))
elif [ "$DUP_COUNT" = "-1" ]; then
  red "Could not parse dedup query response"
  FAIL=$((FAIL + 1))
else
  red "Found ${DUP_COUNT} duplicate chunk(s) after double ingest — dedup broken"
  FAIL=$((FAIL + 1))
fi

# ── 9. Delete by doc_id (Phase 2B) ───────────────────────────────────────────

header "9. Delete by doc_id (Phase 2B)"

DELETE_DOC_ID="smoke-delete-$(date +%s)"
DELETE_TEXT="Phase 2B deletion test sentinel. This chunk must vanish after DELETE."

# Ingest the test doc
INGEST_DEL=$(curl -sf --max-time 15 -X POST "${API}/ingest/text" \
  -H "Content-Type: application/json" \
  -d "{\"doc_id\": \"${DELETE_DOC_ID}\", \"text\": \"${DELETE_TEXT}\"}" \
  2>/dev/null || echo "UNREACHABLE")
check "Delete test doc ingests successfully" "$INGEST_DEL" "ingested"

sleep 1

# Confirm it's retrievable before deletion
PRE_DEL=$(curl -sf --max-time 15 -X POST "${API}/query" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"Phase 2B deletion test sentinel\", \"top_k\": 10}" \
  2>/dev/null || echo "UNREACHABLE")
check "Delete test doc appears in results before DELETE" "$PRE_DEL" "$DELETE_DOC_ID"

# Delete it
DEL_RESULT=$(curl -sf --max-time 15 -X DELETE "${API}/ingest/${DELETE_DOC_ID}" \
  2>/dev/null || echo "UNREACHABLE")
check "DELETE /ingest/{doc_id} returns deleted status" "$DEL_RESULT" "deleted"

sleep 1

# Confirm it's gone
POST_DEL=$(curl -sf --max-time 15 -X POST "${API}/query" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"Phase 2B deletion test sentinel\", \"top_k\": 10}" \
  2>/dev/null || echo "UNREACHABLE")

if echo "$POST_DEL" | grep -q "$DELETE_DOC_ID"; then
  red "Deleted doc_id still appears in query results — delete broken"
  FAIL=$((FAIL + 1))
else
  green "Deleted doc_id no longer appears in query results"
  PASS=$((PASS + 1))
fi

# ── 10. /answer endpoint (Phase 2C) ──────────────────────────────────────────

header "10. Answer endpoint (Phase 2C)"

# Always-run: without OLLAMA_HOST configured the endpoint must return 503
ANSWER_UNCONFIGURED=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST "${API}/answer" \
  -H "Content-Type: application/json" \
  -d '{"query": "what is HersonBot RAG Sandbox"}' \
  2>/dev/null || echo "000")

if [ "$ANSWER_UNCONFIGURED" = "503" ]; then
  green "/answer returns 503 when Ollama is unconfigured"
  PASS=$((PASS + 1))
elif [ "$ANSWER_UNCONFIGURED" = "200" ]; then
  # OLLAMA_HOST is configured — run full Ollama checks instead
  green "/answer is reachable (OLLAMA_HOST configured — running live checks)"
  PASS=$((PASS + 1))

  ANSWER_RESULT=$(curl -sf --max-time 60 -X POST "${API}/answer" \
    -H "Content-Type: application/json" \
    -d '{"query": "what is HersonBot RAG Sandbox"}' \
    2>/dev/null || echo "UNREACHABLE")

  check "/answer returns answer field"  "$ANSWER_RESULT" '"answer"'
  check "/answer returns model field"   "$ANSWER_RESULT" '"model"'
  check "/answer returns sources field" "$ANSWER_RESULT" '"sources"'
  check "/answer returns retrieval_ms"  "$ANSWER_RESULT" "retrieval_ms"
  check "/answer returns generation_ms" "$ANSWER_RESULT" "generation_ms"
else
  red "/answer returned unexpected HTTP ${ANSWER_UNCONFIGURED} (expected 503 or 200)"
  FAIL=$((FAIL + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────

header "Summary"
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""

if [ "$FAIL" -eq 0 ]; then
  green "All checks passed. HersonBot RAG Sandbox is healthy."
  exit 0
else
  red "${FAIL} check(s) failed. Review output above."
  exit 1
fi
