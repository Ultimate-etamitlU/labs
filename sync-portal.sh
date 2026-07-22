#!/bin/bash
# sync-portal.sh — Pull latest labs repo and restart labportal if needed.
# Runs as a systemd service triggered nightly at midnight.
# Safe during active deploys — skips restart if cluster deployment is in progress.
set -euo pipefail

REPO_DIR="/root/labs"
DB_PATH="/root/labs/labportal/labportal.db"
LOG_TAG="sync-portal"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

log "Starting sync"

cd "$REPO_DIR"

# Fetch without touching working tree
git fetch origin main --quiet

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
    log "Already up to date ($LOCAL). Nothing to do."
    exit 0
fi

log "New commits available: $LOCAL -> $REMOTE"

# Identify which files changed between current HEAD and origin/main
CHANGED=$(git diff --name-only HEAD origin/main)
log "Changed files:"
echo "$CHANGED" | sed 's/^/  /'

# Pull
git pull --ff-only origin main
log "Pull complete"

# Check if any portal-relevant file changed
PORTAL_CHANGED=false
while IFS= read -r f; do
    case "$f" in
        labportal/*|cluster-infra-setup.sh|ocp-upi-deploy.sh|ocp-ipi-deploy.sh|ocp-sno-deploy.sh)
            PORTAL_CHANGED=true
            break
            ;;
    esac
done <<< "$CHANGED"

if [ "$PORTAL_CHANGED" = false ]; then
    log "No portal-relevant files changed. Skipping restart."
    exit 0
fi

log "Portal-relevant files changed. Checking for active deployments..."

# Check if any cluster deploy is currently running
if [ -f "$DB_PATH" ]; then
    ACTIVE=$(python3 -c "
import sqlite3
db = sqlite3.connect('$DB_PATH')
count = db.execute(\"SELECT COUNT(*) FROM deployments WHERE status='deploying'\").fetchone()[0]
print(count)
")
    if [ "$ACTIVE" -gt 0 ]; then
        log "SKIP: $ACTIVE active deployment(s) in progress. Portal will pick up changes on next restart."
        exit 0
    fi
fi

log "No active deployments. Restarting labportal..."
systemctl restart labportal
log "labportal restarted successfully."
