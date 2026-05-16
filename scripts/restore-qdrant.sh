#!/usr/bin/env bash
# restore-qdrant.sh — restore hersonbot_qdrant_storage from a backup tarball
# Usage: restore-qdrant.sh <path-to-backup.tar.gz>
#
# WARNING: This DESTROYS existing vector data before restoring.
#          Back up current data first if unsure.
#
# The full stack is stopped before restore and restarted after.
# No sudo required.

set -euo pipefail

STACK_DIR="/opt/grid/stacks/hersonbot"
VOLUME="hersonbot_qdrant_storage"

# ── Argument validation ───────────────────────────────────────────────────────

if [ "$#" -ne 1 ]; then
  echo "Usage: $(basename "$0") <path-to-backup.tar.gz>" >&2
  echo "Example: $(basename "$0") /opt/grid/backups/hersonbot/qdrant-20260515-143022.tar.gz" >&2
  exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: Backup file not found: ${BACKUP_FILE}" >&2
  exit 1
fi

# Refuse to proceed if the file is not a gzip archive
if ! file "$BACKUP_FILE" | grep -q "gzip"; then
  echo "ERROR: File does not appear to be a gzip archive: ${BACKUP_FILE}" >&2
  exit 1
fi

# ── Safety warning ────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RESTORE OPERATION"
echo "  Backup file : ${BACKUP_FILE}"
echo "  Target volume: ${VOLUME}"
echo ""
echo "  This will:"
echo "    1. Stop the entire hersonbot stack"
echo "    2. WIPE all existing vector data in ${VOLUME}"
echo "    3. Restore data from the backup"
echo "    4. Restart the stack"
echo ""
echo "  Existing vector data will be permanently replaced."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -r -p "Type YES to proceed: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted." >&2
  exit 0
fi

# ── Stop the stack ────────────────────────────────────────────────────────────

echo ""
echo "→ Stopping hersonbot stack ..."
docker compose -f "${STACK_DIR}/docker-compose.yml" down

# ── Wipe existing volume data ─────────────────────────────────────────────────

echo "→ Clearing existing volume data ..."
docker run --rm \
  -v "${VOLUME}:/data" \
  alpine \
  sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null || true"

# ── Restore from backup ───────────────────────────────────────────────────────

echo "→ Restoring from ${BACKUP_FILE} ..."
BACKUP_DIR=$(dirname "$BACKUP_FILE")
BACKUP_NAME=$(basename "$BACKUP_FILE")

docker run --rm \
  -v "${VOLUME}:/data" \
  -v "${BACKUP_DIR}:/backup:ro" \
  alpine \
  tar -xzf "/backup/${BACKUP_NAME}" -C /data

echo "✓ Data restored."

# ── Restart the stack ─────────────────────────────────────────────────────────

echo "→ Restarting hersonbot stack ..."
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d

echo ""
echo "✓ Restore complete. Run smoke-test.sh to verify."
