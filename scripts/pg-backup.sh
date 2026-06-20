#!/usr/bin/env bash
# pg-backup.sh — Daily logical backup with off-server encrypted upload
# Per spec [OBS-E1]: Cron 0 3 * * * (daily at 03:00 UTC)
#
# Requirements:
# - rclone configured with B2 remote "b2" (bucket: properbackup-db-backups)
# - GPG passphrase in /etc/pb/backup.key (32-byte random, NOT in git, copy in 1Password)
# - Env vars: PB_BACKUP_HEARTBEAT_URL (healthchecks.io ping URL)
# - PostgreSQL accessible via pg_dump (Docker network or socket)
#
# RPO: 24h (daily dump). For RPO <15min, see [OBS-E2] WAL streaming (post-MVP).
set -euo pipefail

BACKUP_DIR="${PB_BACKUP_DIR:-/var/backups/properbackup}"
DATE=$(date +%Y%m%d-%H%M)
DUMP_FILE="$BACKUP_DIR/pb-$DATE.sql.gz.enc"
RETENTION_DAYS="${PB_BACKUP_RETENTION_DAYS:-7}"

DB_HOST="${PB_DB_HOST:-db}"
DB_USER="${PB_DB_USER:-properbackup}"
DB_NAME="${PB_DB_NAME:-properbackup}"
GPG_KEY_FILE="${PB_GPG_KEY_FILE:-/etc/pb/backup.key}"
B2_REMOTE="${PB_B2_REMOTE:-b2:properbackup-db-backups}"

log() { echo "[$(date -Iseconds)] $*"; }

log "Starting PostgreSQL backup → $DUMP_FILE"
mkdir -p "$BACKUP_DIR"

# 1. Dump + compress + encrypt (streaming pipeline — no plaintext on disk)
pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl \
  | gzip -9 \
  | gpg --symmetric --cipher-algo AES256 --batch --passphrase-file "$GPG_KEY_FILE" \
  > "$DUMP_FILE"

LOCAL_SIZE=$(stat -c%s "$DUMP_FILE")
log "Dump complete: $(numfmt --to=iec $LOCAL_SIZE)"

# 2. Upload to off-server storage (B2/S3/OVH via rclone)
log "Uploading to $B2_REMOTE..."
rclone copy "$DUMP_FILE" "$B2_REMOTE/"

# 3. Verify upload (size check)
REMOTE_SIZE=$(rclone size --json "$B2_REMOTE/$(basename "$DUMP_FILE")" | jq -r '.bytes')
if [ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]; then
  log "ERROR: Size mismatch! local=$LOCAL_SIZE remote=$REMOTE_SIZE"
  exit 1
fi
log "Upload verified: $REMOTE_SIZE bytes on remote"

# 4. Local retention: keep N days, delete older
DELETED=$(find "$BACKUP_DIR" -name "pb-*.sql.gz.enc" -mtime +"$RETENTION_DAYS" -delete -print | wc -l)
if [ "$DELETED" -gt 0 ]; then
  log "Cleaned up $DELETED old backups (retention: ${RETENTION_DAYS}d)"
fi

# 5. Heartbeat ping (healthchecks.io) — alerts if backup doesn't run in 26h
if [ -n "${PB_BACKUP_HEARTBEAT_URL:-}" ]; then
  curl -fsS --retry 3 "$PB_BACKUP_HEARTBEAT_URL" || log "WARNING: Heartbeat ping failed"
fi

log "Backup complete: $DUMP_FILE ($(numfmt --to=iec $LOCAL_SIZE))"
