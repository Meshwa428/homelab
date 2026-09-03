#!/usr/bin/env bash
# =============================================================================
# scripts/idle-critical-update.sh — Idle-gated updates for vpn/dns/traefik
# =============================================================================
#
# vpn, dns, and traefik gate remote access (Tailscale + the reverse proxy),
# so unlike every other service here they are NOT auto-updated by wud the
# moment a new image shows up (see wud.watch=false on their compose.yml
# labels). Instead, this script updates them only during a scheduled quiet
# window, run once nightly via cron (not a WUD trigger — wud's container has
# no `docker` CLI, only the Docker socket, so it can't drive `docker compose`
# itself).
#
# This is a heuristic "quiet window", not a true "nobody anywhere is using
# anything" detector — there's no reliable signal on this box for the latter
# (Traefik's access log wasn't reaching `docker logs` when checked, and this
# box's own long-lived SSH sessions make naive "is anyone logged in" checks
# useless). So: run at a fixed off-hours time, plus skip if a logged-in
# session shows very recent (<SSH_IDLE_GUARD_MINUTES) keystroke activity.
#
# USAGE:
#   ./scripts/idle-critical-update.sh          # normal run (cron)
#   ./scripts/idle-critical-update.sh --force   # skip window+idle checks
#
# CONFIG (shared/.env, optional):
#   IDLE_UPDATE_HOUR=3   # 24h local hour this is allowed to run in (default 3)
#
# =============================================================================

set -euo pipefail

HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="$HOMELAB_DIR/logs/idle-critical-update.log"
mkdir -p "$(dirname "$LOG_FILE")"

FORCE="false"
[[ "${1:-}" == "--force" ]] && FORCE="true"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >/dev/null; }

# ── Config ────────────────────────────────────────────────────────────────────

IDLE_UPDATE_HOUR=3
SSH_IDLE_GUARD_MINUTES=5

if [[ -f "$HOMELAB_DIR/shared/.env" ]]; then
  val=$(grep -E "^IDLE_UPDATE_HOUR=" "$HOMELAB_DIR/shared/.env" | cut -d'=' -f2- | sed "s/^[ '\"\t]*//;s/[ '\"\t]*\$//" || true)
  [[ -n "$val" ]] && IDLE_UPDATE_HOUR="$val"
fi

# ── Gate 1: quiet-hour window ────────────────────────────────────────────────

if [[ "$FORCE" != "true" ]]; then
  current_hour=$((10#$(date +%H)))
  if [[ "$current_hour" -ne "$IDLE_UPDATE_HOUR" ]]; then
    log "Skip: outside quiet window (current hour=$current_hour, window=$IDLE_UPDATE_HOUR)"
    exit 0
  fi
fi

# ── Gate 2: recent SSH/tty keystroke activity (best-effort, fails safe) ─────
# `w`'s bare "N:NN" IDLE value is genuinely ambiguous from the string alone —
# it means MM:SS below 1h idle and HH:MM above it, with no way to tell which
# from the text (confirmed live: a session active 67 seconds ago showed IDLE
# "1:07", which naively read as hours:minutes would wrongly look like 1h7m
# idle). So bare "N:NN" is always read as the SHORTER interpretation
# (minutes:seconds) here — the fail-safe direction for a script whose only
# job is "don't touch this while someone's around": worst case a
# genuinely-long-idle session gets misjudged as short and an update is
# deferred one more night, never the reverse. A trailing "m" (procps-ng's
# marker on some non-tty/graphical sessions, e.g. an X11 console) is parsed
# the same way. "Ndays" and "SS.SSs" are unambiguous and read as documented.
# Anything else is treated as ACTIVE (skip) rather than guessed at.

idle_seconds_for_line() {
  local idle="$1"
  if [[ "$idle" =~ ^([0-9]+)days?$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 86400 ))
  elif [[ "$idle" =~ ^([0-9]+):([0-9]+)m?$ ]]; then
    echo $(( (10#${BASH_REMATCH[1]}) * 60 + (10#${BASH_REMATCH[2]}) ))
  elif [[ "$idle" =~ ^([0-9]+)\.[0-9]+s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo -1  # unrecognized shape -> caller treats as "active"
  fi
}

if [[ "$FORCE" != "true" ]] && command -v w >/dev/null 2>&1; then
  guard_seconds=$(( SSH_IDLE_GUARD_MINUTES * 60 ))
  while IFS= read -r idle_field; do
    [[ -z "$idle_field" ]] && continue
    secs=$(idle_seconds_for_line "$idle_field")
    if [[ "$secs" -lt "$guard_seconds" ]]; then
      log "Skip: session idle-time '$idle_field' looks active (<${SSH_IDLE_GUARD_MINUTES}m or unrecognized)"
      exit 0
    fi
  done < <(w -h 2>/dev/null | awk '{print $4}')
fi

log "Idle window confirmed — checking vpn, dns, traefik for updates"

# ── Update one service if its image actually changed ────────────────────────

update_if_changed() {
  local service="$1" compose_rel="$2"
  local compose_file="$HOMELAB_DIR/$compose_rel"
  local before after

  before=$(docker compose --env-file "$HOMELAB_DIR/shared/.env" -f "$compose_file" images -q 2>/dev/null | sort | tr '\n' ' ')
  docker compose --env-file "$HOMELAB_DIR/shared/.env" -f "$compose_file" pull >>"$LOG_FILE" 2>&1
  after=$(docker compose --env-file "$HOMELAB_DIR/shared/.env" -f "$compose_file" images -q 2>/dev/null | sort | tr '\n' ' ')

  if [[ "$before" == "$after" ]]; then
    log "$service: already up to date"
    return
  fi

  log "$service: new image pulled, recreating"
  if echo "yes" | "$HOMELAB_DIR/lab" restart "$service" >>"$LOG_FILE" 2>&1; then
    log "$service: restarted successfully"
  else
    log "$service: restart FAILED — check manually, not proceeding to next service"
    exit 1
  fi

  # Give the freshly-recreated container a moment before moving on to the
  # next critical service, rather than hammering all three back-to-back.
  sleep 10
}

update_if_changed vpn core/vpn/compose.yml
update_if_changed dns core/dns/compose.yml
update_if_changed traefik core/traefik/compose.yml

log "Done."
