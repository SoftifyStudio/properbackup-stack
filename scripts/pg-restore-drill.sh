#!/usr/bin/env bash
# pg-restore-drill.sh — Quarterly restore drill (spec [OBS-E4])
#
# Performs a full restore to a SEPARATE staging database to verify:
# 1. Backup is decryptable (GPG key works)
# 2. Data is complete (sample queries)
# 3. RTO is within target (<2h)
#
# This does NOT affect production. Safe to run anytime.
#
# Usage: ./pg-restore-drill.sh [backup-file.sql.gz.enc]
#        If no file given, downloads latest from B2.
set -euo pipefail

DRILL_DB="${PB_DRILL_DB:-properbackup_drill}"
DB_HOST="${PB_DB_HOST:-db}"
DB_USER="${PB_DB_USER:-properbackup}"
DB_ADMIN_USER="${PB_DB_ADMIN_USER:-postgres}"
GPG_KEY_FILE="${PB_GPG_KEY_FILE:-/etc/pb/backup.key}"
B2_REMOTE="${PB_B2_REMOTE:-b2:properbackup-db-backups}"

log() { echo "[$(date -Iseconds)] $*"; }
die() { log "FATAL: $*"; exit 1; }

START_TIME=$(date +%s)

# Get backup file
BACKUP_FILE="${1:-}"
if [ -z "$BACKUP_FILE" ]; then
  log "No backup specified — downloading latest from B2..."
  LATEST=$(rclone lsf "$B2_REMOTE/" --format "tp" | sort -r | head -1 | cut -d';' -f2)
  [ -n "$LATEST" ] || die "No backups found on B2"
  log "Latest: $LATEST"
  rclone copy "$B2_REMOTE/$LATEST" /tmp/
  BACKUP_FILE="/tmp/$LATEST"
fi

[ -f "$BACKUP_FILE" ] || die "Backup file not found: $BACKUP_FILE"
[ -f "$GPG_KEY_FILE" ] || die "GPG key not found: $GPG_KEY_FILE"

log "=== RESTORE DRILL (quarterly test) ==="
log "Backup: $BACKUP_FILE"
log "Drill DB: $DRILL_DB (production NOT affected)"
log ""

# 1. Create fresh drill database
log "Step 1: Creating drill database..."
psql -h "$DB_HOST" -U "$DB_ADMIN_USER" -c "DROP DATABASE IF EXISTS $DRILL_DB;"
psql -h "$DB_HOST" -U "$DB_ADMIN_USER" -c "CREATE DATABASE $DRILL_DB OWNER $DB_USER;"

# 2. Decrypt + restore to drill DB
log "Step 2: Decrypting and restoring to drill DB..."
gpg --decrypt --batch --passphrase-file "$GPG_KEY_FILE" "$BACKUP_FILE" \
  | gunzip \
  | psql -h "$DB_HOST" -U "$DB_USER" -d "$DRILL_DB" --quiet

# 3. Verify data integrity
log "Step 3: Verifying data integrity..."
CHECKS_PASSED=0
CHECKS_TOTAL=0

check() {
  local description="$1"
  local query="$2"
  local expected_min="${3:-1}"

  CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
  RESULT=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DRILL_DB" -t -c "$query" 2>/dev/null | tr -d ' ')

  if [ "${RESULT:-0}" -ge "$expected_min" ]; then
    log "  ✓ $description: $RESULT"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
  else
    log "  ✗ $description: $RESULT (expected >= $expected_min)"
  fi
}

check "Users exist" "SELECT COUNT(*) FROM users;"
check "Servers registered" "SELECT COUNT(*) FROM servers;"
check "Archive snapshots" "SELECT COUNT(*) FROM archive_snapshot;"
check "Subscriptions" "SELECT COUNT(*) FROM users WHERE subscription_status IS NOT NULL;" 0
check "Recent data (<26h)" "SELECT COUNT(*) FROM users WHERE created_at > now() - interval '26 hours';" 0

# 4. Cleanup drill DB
log "Step 4: Cleaning up drill database..."
psql -h "$DB_HOST" -U "$DB_ADMIN_USER" -c "DROP DATABASE $DRILL_DB;"

# 5. Report
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_MIN=$((DURATION / 60))

log ""
log "=== DRILL RESULTS ==="
log "  Checks passed: $CHECKS_PASSED / $CHECKS_TOTAL"
log "  Duration: ${DURATION_MIN}m ${DURATION}s"
log "  RTO target: <120 min"
if [ "$DURATION_MIN" -lt 120 ]; then
  log "  RTO status: PASS (${DURATION_MIN}m < 120m)"
else
  log "  RTO status: FAIL (${DURATION_MIN}m >= 120m) — optimize restore process!"
fi
log ""
log "Document this drill result in: properbackup-docs/operations/drill-log.md"
log "  Date: $(date -I)"
log "  Duration: ${DURATION_MIN} min"
log "  Checks: $CHECKS_PASSED/$CHECKS_TOTAL"
log "  Issues: (note any issues)"
