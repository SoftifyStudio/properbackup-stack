#!/usr/bin/env bash
# pg-restore.sh — Disaster recovery: restore PostgreSQL from encrypted backup
# Per spec [OBS-E3]: Restore procedure
#
# Usage:
#   ./pg-restore.sh <backup-file.sql.gz.enc>
#   ./pg-restore.sh --from-b2 pb-20260526-0300.sql.gz.enc
#
# Pre-conditions:
# - PostgreSQL container/service running
# - GPG key available at /etc/pb/backup.key
# - Buffer service STOPPED (no new writes during restore)
# - Maintenance window announced to clients
set -euo pipefail

DB_HOST="${PB_DB_HOST:-db}"
DB_USER="${PB_DB_USER:-properbackup}"
DB_NAME="${PB_DB_NAME:-properbackup}"
DB_ADMIN_USER="${PB_DB_ADMIN_USER:-postgres}"
GPG_KEY_FILE="${PB_GPG_KEY_FILE:-/etc/pb/backup.key}"
B2_REMOTE="${PB_B2_REMOTE:-b2:properbackup-db-backups}"

log() { echo "[$(date -Iseconds)] $*"; }
die() { log "FATAL: $*"; exit 1; }

if [ $# -lt 1 ]; then
  echo "Usage: $0 <backup-file.sql.gz.enc>"
  echo "       $0 --from-b2 <remote-filename>"
  exit 1
fi

# Handle --from-b2 flag
BACKUP_FILE=""
if [ "$1" = "--from-b2" ]; then
  [ $# -lt 2 ] && die "Missing remote filename"
  BACKUP_FILE="/tmp/$2"
  log "Downloading from B2: $B2_REMOTE/$2"
  rclone copy "$B2_REMOTE/$2" /tmp/
  [ -f "$BACKUP_FILE" ] || die "Download failed: $BACKUP_FILE not found"
else
  BACKUP_FILE="$1"
  [ -f "$BACKUP_FILE" ] || die "File not found: $BACKUP_FILE"
fi

[ -f "$GPG_KEY_FILE" ] || die "GPG key not found: $GPG_KEY_FILE"

log "=== DISASTER RECOVERY: PostgreSQL Restore ==="
log "Backup: $BACKUP_FILE"
log "Target: $DB_HOST/$DB_NAME"
log ""
log "⚠️  WARNING: This will DROP and recreate the database!"
log "⚠️  Make sure the buffer service is STOPPED."
log ""

# Safety prompt
if [ -t 0 ]; then
  read -p "Continue? (type 'RESTORE' to confirm): " CONFIRM
  [ "$CONFIRM" = "RESTORE" ] || die "Aborted by user"
fi

# 1. Backup current state (safety net)
PRE_RESTORE="/tmp/pre-restore-$(date +%s).sql"
log "Step 1: Backing up current state → $PRE_RESTORE"
pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl > "$PRE_RESTORE" 2>/dev/null || true
log "  Pre-restore backup: $(stat -c%s "$PRE_RESTORE" 2>/dev/null || echo 0) bytes"

# 2. Drop and recreate database
log "Step 2: Dropping and recreating database..."
psql -h "$DB_HOST" -U "$DB_ADMIN_USER" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME' AND pid <> pg_backend_pid();" 2>/dev/null || true
psql -h "$DB_HOST" -U "$DB_ADMIN_USER" -c "DROP DATABASE IF EXISTS $DB_NAME;"
psql -h "$DB_HOST" -U "$DB_ADMIN_USER" -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

# 3. Decrypt + decompress + restore
log "Step 3: Decrypting and restoring..."
gpg --decrypt --batch --passphrase-file "$GPG_KEY_FILE" "$BACKUP_FILE" \
  | gunzip \
  | psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" --quiet

# 4. Verify
log "Step 4: Verifying restore..."
USER_COUNT=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')
SNAPSHOT_COUNT=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM archive_snapshot;" 2>/dev/null | tr -d ' ')

log "  Users: $USER_COUNT"
log "  Archive snapshots: $SNAPSHOT_COUNT"

if [ "${USER_COUNT:-0}" -eq 0 ]; then
  log "WARNING: Zero users after restore — verify backup integrity!"
fi

log ""
log "=== Restore complete ==="
log ""
log "Post-restore checklist:"
log "  [ ] Start buffer: docker compose start buffer"
log "  [ ] Check /health returns 200"
log "  [ ] Send test Stripe webhook"
log "  [ ] Verify agent_metrics — agents reconnecting"
log "  [ ] Update status page: green"
