#!/bin/bash
# =============================================================================
# backup.sh — Homelab Backup Script
# Usage: ./scripts/backup.sh [service] [--no-stop]
#   ./scripts/backup.sh              # backs up everything
#   ./scripts/backup.sh ollama       # backs up only ollama
#   ./scripts/backup.sh --no-stop    # skips container stop/start (risky)
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="$HOMELAB_DIR/backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_TARGET="$BACKUP_DIR/$TIMESTAMP"
STOP_CONTAINERS=true
LOG_FILE="$BACKUP_DIR/backup.log"

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

# --- Parse args --------------------------------------------------------------
TARGET_SERVICE=""
for arg in "$@"; do
  case $arg in
    --no-stop) STOP_CONTAINERS=false ;;
    *)         TARGET_SERVICE="$arg" ;;
  esac
done

# --- Service map: name -> compose file | data dirs ---------------------------
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

# Named Docker volumes (no bind mount on disk)
DOCKER_VOLUMES=("open-webui-data")

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

backup_dir() {
  local src="$HOMELAB_DIR/$1"
  local dest="$BACKUP_TARGET/$1"
  if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
    mkdir -p "$(dirname "$dest")"
    sudo cp -r "$src" "$(dirname "$dest")/"
    sudo chown -R "$USER:$USER" "$dest"
    info "  ✓ $1"
  else
    warn "  – skipped (empty/missing): $1"
  fi
}

backup_docker_volume() {
  local volume="$1"
  local dest="$BACKUP_TARGET/docker-volumes/$volume"
  mkdir -p "$dest"
  if docker volume inspect "$volume" &>/dev/null; then
    docker run --rm \
      -v "$volume":/source:ro \
      -v "$dest":/dest \
      alpine sh -c "cp -r /source/. /dest/" 2>>"$LOG_FILE"
    info "  ✓ docker volume: $volume"
  else
    warn "  – docker volume not found, skipping: $volume"
  fi
}

backup_service() {
  local name="$1"
  local entry="${SERVICES[$name]}"
  local compose_file="${entry%%|*}"
  local dirs="${entry##*|}"

  info "--- $name ---"
  $STOP_CONTAINERS && [ -n "$compose_file" ] && stop_service "$compose_file"
  for dir in $dirs; do backup_dir "$dir"; done
  $STOP_CONTAINERS && [ -n "$compose_file" ] && start_service "$compose_file"
}

# --- Main --------------------------------------------------------------------
mkdir -p "$BACKUP_TARGET" "$(dirname "$LOG_FILE")"
echo "" >> "$LOG_FILE"
info "=========================================="
info "Backup started:  $TIMESTAMP"
info "Destination:     backups/$TIMESTAMP"
info "=========================================="

# Always back up shared config
backup_dir "shared"
cp "$HOMELAB_DIR/.gitignore" "$BACKUP_TARGET/" 2>/dev/null || true

if [ -n "$TARGET_SERVICE" ]; then
  [ -z "${SERVICES[$TARGET_SERVICE]+_}" ] \
    && error "Unknown service '$TARGET_SERVICE'. Valid: ${!SERVICES[*]}"
  backup_service "$TARGET_SERVICE"
  BACKED_UP="$TARGET_SERVICE"
else
  for service in "${!SERVICES[@]}"; do
    backup_service "$service"
  done
  info "--- Docker named volumes ---"
  for vol in "${DOCKER_VOLUMES[@]}"; do
    backup_docker_volume "$vol"
  done
  BACKED_UP="FULL — ${!SERVICES[*]}"
fi

# --- Write manifest ----------------------------------------------------------
{
  echo "================================================"
  echo "  Homelab Backup Manifest"
  echo "================================================"
  echo "  Date:     $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  Host:     $(hostname)"
  echo "  Services: $BACKED_UP"
  echo "  Stopped:  $STOP_CONTAINERS"
  echo "================================================"
  echo ""
  echo "Files:"
  find "$BACKUP_TARGET" | sort | sed "s|$BACKUP_TARGET/||" | grep -v '^$'
} > "$BACKUP_TARGET/MANIFEST.txt"

# --- Compress ----------------------------------------------------------------
info "Compressing..."
cd "$BACKUP_DIR"
tar -czf "$TIMESTAMP.tar.gz" "$TIMESTAMP/" && rm -rf "$TIMESTAMP/"
BACKUP_SIZE=$(du -sh "$BACKUP_DIR/$TIMESTAMP.tar.gz" | cut -f1)
info "Saved: backups/$TIMESTAMP.tar.gz ($BACKUP_SIZE)"

# --- Rotate: keep last 7 backups ---------------------------------------------
info "Rotating old backups (keeping last 7)..."
ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm --

info "=========================================="
info "Backup complete."
info "=========================================="
