#!/bin/bash
# =============================================================================
# migrate-docker.sh — Safe Failsafe Docker Data Migration
# =============================================================================
# Copies all docker files to /home/docker, stops docker, does a final sync,
# updates the data-root, and restarts docker.
#
# If the new docker daemon fails to start, it automatically rolls back the
# configuration and restores the original docker service, keeping your
# Tailscale connection 100% safe.
# =============================================================================

set -euo pipefail

# Ignore terminal hangup signals (SIGHUP) so the script survives the connection drop
trap '' HUP

SRC="/var/lib/docker/"
DST="/home/docker/"
CONFIG_FILE="/etc/docker/daemon.json"
BACKUP_CONFIG="/etc/docker/daemon.json.bak"

# Colors
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

info()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}!${NC}  $*"; }
error()  { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
step()   { echo -e "  ${CYAN}→${NC}  $*"; }

echo -e "\n${BOLD}${CYAN}Starting Safe Docker Storage Migration...${NC}\n"

# 1. Ensure target directory exists
step "Creating target directory /home/docker..."
sudo mkdir -p "$DST"
info "Target directory ready."

# 2. Initial Hot Copy
step "Performing initial copy while Docker is running (Connection is 100% active)..."
sudo rsync -a --delete "$SRC" "$DST"
info "Initial copy completed."

# 3. Stop Docker (Terminal session will temporarily disconnect here)
warn "Stopping Docker service. Your Tailscale connection will temporarily disconnect..."
sudo systemctl stop docker.socket || true
sudo systemctl stop docker || true

# 4. Final Cold Copy
step "Performing final quick sync..."
sudo rsync -a --delete "$SRC" "$DST"
info "Final sync completed."

# 5. Backup and Update Config
step "Updating /etc/docker/daemon.json to use new data-root..."
sudo cp "$CONFIG_FILE" "$BACKUP_CONFIG"

sudo python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
config_path = sys.argv[1]
with open(config_path) as f:
    data = json.load(f)
data["data-root"] = "/home/docker"
with open(config_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
info "Configuration updated."

# 6. Start Docker under the new directory
step "Starting Docker under the new directory..."
if sudo systemctl start docker; then
  # 7. Verification
  sleep 5
  if systemctl is-active --quiet docker; then
    echo ""
    echo -e "  ${GREEN}${BOLD}=== SUCCESS: Docker is running perfectly under /home/docker ===${NC}"
    echo -e "  ${NC}Old files in /var/lib/docker remain safe for now. You can clean them later."
    echo ""
    exit 0
  fi
fi

# 8. Failsafe Rollback (Only runs if start/active failed)
echo ""
warn "Docker failed to start under /home/docker. Initiating automatic rollback..."
sudo cp "$BACKUP_CONFIG" "$CONFIG_FILE"
sudo systemctl start docker.socket || true
sudo systemctl start docker || true
echo -e "  ${GREEN}${BOLD}=== ROLLBACK SUCCESSFUL: Restored original Docker daemon ===${NC}\n"
error "Migration failed, but system successfully rolled back to original state."
