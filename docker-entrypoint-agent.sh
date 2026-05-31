#!/bin/sh
set -e

CONF_DIR="/data/conf.d"
GLOBAL_YML="$CONF_DIR/global.yml"
BUFFER_URL="${PROPERBACKUP_BUFFER_URL:-http://buffer:7100}"
UPLOAD_TOKEN="${PROPERBACKUP_UPLOAD_TOKEN:-dev-token-local}"
OWNER_EMAIL="${PROPERBACKUP_OWNER_EMAIL:-}"
SERVER_NAME="${PROPERBACKUP_SERVER_NAME:-Agent VPS}"

# ── Wait for buffer to be healthy ──────────────────────────────────────
echo "[agent-init] Waiting for buffer at $BUFFER_URL ..."
TRIES=0
while [ $TRIES -lt 60 ]; do
  if wget -q --spider "$BUFFER_URL/health" 2>/dev/null; then
    echo "[agent-init] Buffer is healthy."
    break
  fi
  TRIES=$((TRIES + 1))
  sleep 2
done
if [ $TRIES -ge 60 ]; then
  echo "[agent-init] ERROR: Buffer not reachable after 120s. Starting agent anyway."
fi

# ── Auto-register demo user & server ───────────────────────────────────
if [ -n "$OWNER_EMAIL" ]; then
  OWNER_PASS="${PROPERBACKUP_OWNER_PASSWORD:-ProperBackup2026!}"
  SERVER_ID="${PROPERBACKUP_SERVER_ID:-demo-server-001}"

  echo "[agent-init] Ensuring owner account: $OWNER_EMAIL"
  wget -q -O /dev/null --post-data "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$OWNER_PASS\"}" \
    --header="Content-Type: application/json" \
    "$BUFFER_URL/auth/register" 2>/dev/null || true

  echo "[agent-init] Auto-registering server: $SERVER_ID for $OWNER_EMAIL"
  wget -q -O /dev/null --post-data "{\"machineId\":\"$SERVER_ID\",\"ownerEmail\":\"$OWNER_EMAIL\",\"name\":\"$SERVER_NAME\"}" \
    --header="Content-Type: application/json" \
    --header="Authorization: Bearer $UPLOAD_TOKEN" \
    "$BUFFER_URL/agent/auto-register" 2>/dev/null || true

  echo "[agent-init] Auto-registration complete."
fi

# ── Generate global.yml from environment variables ─────────────────────
if [ ! -f "$GLOBAL_YML" ] || [ "${PROPERBACKUP_FORCE_CONFIG:-false}" = "true" ]; then
  echo "[agent-init] Generating $GLOBAL_YML ..."

  if [ -z "$PROPERBACKUP_SERVER_ID" ]; then
    echo "ERROR: PROPERBACKUP_SERVER_ID is required."
    exit 1
  fi

  mkdir -p "$CONF_DIR"

  cat > "$GLOBAL_YML" <<EOF
agent:
  user_id: "${PROPERBACKUP_USER_ID:-auto}"
  server_id: "$PROPERBACKUP_SERVER_ID"
  buffer_url: "$BUFFER_URL"
  upload_token: "$UPLOAD_TOKEN"
  encryption_password: "${PROPERBACKUP_ENCRYPTION_PASSWORD:-change-me}"
  state_dir: "/data/state"
  poll_interval_seconds: ${PROPERBACKUP_POLL_INTERVAL:-60}

default_excludes:
  - "*.log"
  - ".git"
  - "node_modules"
  - "__pycache__"
  - ".DS_Store"
EOF

  echo "[agent-init] Generated $GLOBAL_YML"
fi

# ── Generate service config for /data/backup-source ────────────────────
SERVICE_COUNT=$(ls "$CONF_DIR"/*.yml 2>/dev/null | grep -v global.yml | wc -l)
if [ "$SERVICE_COUNT" -eq 0 ]; then
  cat > "$CONF_DIR/backup.yml" <<EOF
service: backup
enabled: true
paths:
  - /data/backup-source
exclude:
  - "*.log"
  - "*.tmp"
  - "cache"
EOF
  echo "[agent-init] Generated default service config."
fi

# ── Run agent from fat JAR ────────────────────────────────────────────
AGENT_JAR=""

# Find the shadow JAR (contains -all in name)
for jar in /opt/properbackup-agent/*.jar; do
  if echo "$jar" | grep -q "all"; then
    AGENT_JAR="$jar"
    break
  fi
done

# Fallback to first JAR if no -all found
if [ -z "$AGENT_JAR" ]; then
  for jar in /opt/properbackup-agent/*.jar; do
    if [ -f "$jar" ]; then
      AGENT_JAR="$jar"
      break
    fi
  done
fi

if [ ! -f "$AGENT_JAR" ]; then
  echo "ERROR: Agent JAR not found in /opt/properbackup-agent/"
  ls -la /opt/properbackup-agent/ 2>/dev/null
  exit 1
fi

echo "[agent-init] Starting agent: $AGENT_JAR"
exec java -jar "$AGENT_JAR" \
  --config "$GLOBAL_YML" \
  --conf-dir "$CONF_DIR" \
  --headless \
  "$@"
