#!/bin/bash
# =============================================================================
# restore.sh — Homelab Restore Script
# Usage: ./scripts/restore.sh <backup-file.tar.gz> [service]
#   ./scripts/restore.sh backups/2025-01-01_12-00-00.tar.gz          # full restore
#   ./scripts/restore.sh backups/2025-01-01_12-00-00.tar.gz ollama   # single service
#   ./scripts/restore.sh --list                                        # list backups
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$HOMELAB_DIR/backups"
LOG_FILE="$BACKUP_DIR/restore.log"

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
ask()   { echo -e "${BLUE}[ASK]${NC}   $1"; }

# --- List mode ---------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then
  echo ""
  echo "Available backups:"
  echo "------------------"
  shopt -s nullglob
  archives=("$BACKUP_DIR"/*.tar.gz)
  if [ ${#archives[@]} -eq 0 ]; then
    echo "No backups found in $BACKUP_DIR"
  else
    for archive in "${archives[@]}"; do
      SIZE=$(du -sh "$archive" | cut -f1)
      echo ""
      echo "► $(basename "$archive")  [$SIZE]"
      tar -xzf "$archive" --wildcards "*/MANIFEST.txt" -O 2>/dev/null \
        | grep -E "Date:|Host:|Services:|Stopped:" \
        | sed 's/^/    /'
    done
  fi
  echo ""
  exit 0
fi

# --- Args --------------------------------------------------------------------
BACKUP_FILE="${1:-}"
TARGET_SERVICE="${2:-}"

[ -z "$BACKUP_FILE" ] && error "Usage: ./scripts/restore.sh <backup.tar.gz> [service]"

# Resolve path (allow relative or absolute)
[[ "$BACKUP_FILE" != /* ]] && BACKUP_FILE="$HOMELAB_DIR/$BACKUP_FILE"
[ -f "$BACKUP_FILE" ] || error "Backup file not found: $BACKUP_FILE"

# --- Service map (must match backup.sh) --------------------------------------
declare -A SERVICES=(
  [dns]="core/dns/compose.yml|core/dns/config core/dns/data core/dns/ts-dns-state"
  [reverse-proxy]="core/reverse-proxy/compose.yml|core/reverse-proxy/data core/reverse-proxy/letsencrypt core/reverse-proxy/ts-proxy-state"
  [vpn]="core/vpn/compose.yml|core/vpn/state"
  [portainer]="core/management/portainer/compose.yml|core/management/portainer/data"
  [watchtower]="core/management/watchtower/compose.yml|"
  [filebrowser]="services/filebrowser/compose.yml|services/filebrowser/config services/filebrowser/data"
  [vscode]="services/vscode/compose.yml|services/vscode/config services/vscode/projects"
  [ollama]="services/ollama/compose.yml|services/ollama/runtime"
  [open-webui]="services/open-webui/compose.yml|"
  [honeygain]="apps/honeygain/compose.yml|"
)

DOCKER_VOLUMES=("open-webui-data")

# --- Confirm -----------------------------------------------------------------
echo ""
warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
warn "  This will OVERWRITE current data with:"
warn "  $(basename "$BACKUP_FILE")"
[ -n "$TARGET_SERVICE" ] && warn "  Service: $TARGET_SERVICE only" || warn "  ALL services"
warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""
ask "Type 'yes' to continue: "
read -r CONFIRM
[ "$CONFIRM" != "yes" ] && { echo "Aborted."; exit 0; }

# --- Extract to temp dir -----------------------------------------------------
EXTRACT_DIR=$(mktemp -d)
trap 'rm -rf "$EXTRACT_DIR"' EXIT

info "Extracting $(basename "$BACKUP_FILE")..."
tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR"

# The archive contains a single timestamped folder
BACKUP_ROOT=$(ls "$EXTRACT_DIR")
BACKUP_DATA="$EXTRACT_DIR/$BACKUP_ROOT"
[ -d "$BACKUP_DATA" ] || error "Unexpected archive structure. Expected a single top-level folder."
info "Backup snapshot: $BACKUP_ROOT"

# --- Helpers -----------------------------------------------------------------
stop_service() {
  info "Stopping: $1"
  docker compose -f "$HOMELAB_DIR/$1" down 2>>"$LOG_FILE" \
    || warn "Could not stop $1 (may already be down)"
}

start_service() {
  info "Starting: $1"
  docker compose -f "$HOMELAB_DIR/$1" up -d 2>>"$LOG_FILE" \
    || warn "Could not start $1"
}

restore_dir() {
  local src="$BACKUP_DATA/$1"
  local dest="$HOMELAB_DIR/$1"
  if [ -d "$src" ]; then
    mkdir -p "$dest"
    sudo rm -rf "${dest:?}/"*  2>/dev/null || true
    sudo cp -r "$src/." "$dest/"
    info "  ✓ $1"
  else
    warn "  – not found in backup, skipping: $1"
  fi
}

restore_docker_volume() {
  local volume="$1"
  local src="$BACKUP_DATA/docker-volumes/$volume"
  if [ -d "$src" ]; then
    docker volume create "$volume" &>/dev/null || true
    docker run --rm \
      -v "$src":/source:ro \
      -v "$volume":/dest \
      alpine sh -c "rm -rf /dest/* && cp -r /source/. /dest/" 2>>"$LOG_FILE"
    info "  ✓ docker volume: $volume"
  else
    warn "  – docker volume backup not found, skipping: $volume"
  fi
}

restore_service() {
  local name="$1"
  local entry="${SERVICES[$name]}"
  local compose_file="${entry%%|*}"
  local dirs="${entry##*|}"

  info "--- $name ---"
  stop_service "$compose_file"
  for dir in $dirs; do restore_dir "$dir"; done
  start_service "$compose_file"
}

# --- Main --------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
echo "" >> "$LOG_FILE"
info "=========================================="
info "Restore started: $(date +"%Y-%m-%d_%H-%M-%S")"
info "From backup:     $(basename "$BACKUP_FILE")"
info "=========================================="

# Restore shared config
restore_dir "shared"
[ -f "$BACKUP_DATA/.gitignore" ] && cp "$BACKUP_DATA/.gitignore" "$HOMELAB_DIR/"

if [ -n "$TARGET_SERVICE" ]; then
  [ -z "${SERVICES[$TARGET_SERVICE]+_}" ] \
    && error "Unknown service '$TARGET_SERVICE'. Valid: ${!SERVICES[*]}"
  restore_service "$TARGET_SERVICE"
else
  for service in "${!SERVICES[@]}"; do
    restore_service "$service"
  done
  info "--- Docker named volumes ---"
  for vol in "${DOCKER_VOLUMES[@]}"; do
    restore_docker_volume "$vol"
  done
fi

info "=========================================="
info "Restore complete."
info "=========================================="
