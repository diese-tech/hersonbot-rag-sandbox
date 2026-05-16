#!/usr/bin/env bash
# backup-qdrant.sh — snapshot hersonbot_qdrant_storage to a timestamped tarball
# No sudo required. Safe to run while Qdrant is running.
# Output: /opt/grid/backups/hersonbot/qdrant-YYYYMMDD-HHMMSS.tar.gz

set -euo pipefail

VOLUME="hersonbot_qdrant_storage"
BACKUP_DIR="/opt/grid/backups/hersonbot"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/qdrant-${TIMESTAMP}.tar.gz"

# Verify the volume exists before attempting backup
if ! docker volume inspect "$VOLUME" > /dev/null 2>&1; then
  echo "ERROR: Volume '$VOLUME' not found. Is the hersonbot stack running?" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "→ Backing up volume '${VOLUME}' ..."
docker run --rm \
  -v "${VOLUME}:/source:ro" \
  -v "${BACKUP_DIR}:/backup" \
  alpine \
  tar -czf "/backup/qdrant-${TIMESTAMP}.tar.gz" -C /source .

if [ -f "$BACKUP_FILE" ]; then
  SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
  echo "✓ Backup complete: ${BACKUP_FILE} (${SIZE})"
else
  echo "ERROR: Backup file was not created." >&2
  exit 1
fi

# Show all backups and total size
echo ""
echo "All backups in ${BACKUP_DIR}:"
ls -lh "${BACKUP_DIR}/"
