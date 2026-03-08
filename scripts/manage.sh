#!/bin/bash
# =============================================================================
# manage.sh — Homelab Service Manager
# =============================================================================
# Services are auto-discovered by finding all compose.yml files in the repo.
# Boot order is derived automatically via topological sort.
# Only services with dependencies need to be declared — in scripts/services.dep
# Circular dependencies are detected and blocked before anything starts.
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_FILE="$HOMELAB_DIR/scripts/services.dep"

# --- Colors ------------------------------------------------------------------
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

info()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}!${NC}  $*"; }
error()  { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
step()   { echo -e "  ${BLUE}→${NC}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}$*${NC}\n"; }

# =============================================================================
# Auto-discovery
# =============================================================================
# Scans the repo for compose.yml files and builds SERVICES[name]=path.
# Service name = the directory containing the compose.yml.
# e.g. services/ollama/compose.yml → ollama

declare -A SERVICES=()

_discover() {
  while IFS='|' read -r name path; do
    if [[ -n "${SERVICES[$name]+_}" ]]; then
      error "Duplicate service name '$name' found at:
       existing: ${SERVICES[$name]}
       conflict: $path
      Rename one of the directories to resolve."
    fi
    SERVICES["$name"]="$path"
  done < <(
    find "$HOMELAB_DIR" -name "compose.yml" -not -path "*/.git/*" 2>/dev/null \
      | while read -r f; do
          rel="${f#$HOMELAB_DIR/}"
          name=$(basename "$(dirname "$f")")
          echo "$name|$rel"
        done \
      | sort
  )
}

# =============================================================================
# Dependency loading
# =============================================================================
# Reads scripts/services.dep and builds DEPS[service]="dep1 dep2"
# Only services listed in the file are tracked — all others have no deps.

declare -A DEPS=()

_load_deps() {
  [[ -f "$DEPS_FILE" ]] || return 0

  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]]  && continue

    local service deps_str
    service=$(echo "$line" | awk -F'->' '{ gsub(/[[:space:]]/,"",$1); print $1 }')
    deps_str=$(echo "$line" | awk -F'->' '{ gsub(/^[[:space:]]+/,"",$2); print $2 }')

    [[ -z "$service" || -z "$deps_str" ]] && continue
    DEPS["$service"]="$deps_str"
  done < "$DEPS_FILE"
}

# =============================================================================
# Topological sort — Kahn's algorithm
# =============================================================================
# Input:  list of service names
# Output: sorted order printed to stdout, one per line
# Exits with a clear error message if a cycle is detected.
#
# Services with no deps are sorted alphabetically among themselves.
# Deps always come before the services that need them.

_topo_sort() {
  local -a services=("$@")

  # Validate all declared deps actually exist
  for s in "${services[@]}"; do
    for dep in ${DEPS[$s]:-}; do
      local found=false
      for svc in "${services[@]}"; do [[ "$svc" == "$dep" ]] && found=true && break; done
      if ! $found; then
        error "services.dep: '$s' depends on '$dep', but '$dep' has no compose.yml.
       Check the spelling or create the service."
      fi
    done
  done

  # Build in-degree table and adjacency list
  declare -A indegree=()
  declare -A adj=()

  for s in "${services[@]}"; do
    indegree["$s"]=0
    adj["$s"]=""
  done

  for s in "${services[@]}"; do
    for dep in ${DEPS[$s]:-}; do
      adj["$dep"]+=" $s"
      indegree["$s"]=$(( indegree[$s] + 1 ))
    done
  done

  # Seed the queue with all zero-indegree services, alphabetically
  local -a queue=()
  for s in "${services[@]}"; do
    [[ "${indegree[$s]}" -eq 0 ]] && queue+=("$s")
  done
  mapfile -t queue < <(printf '%s\n' "${queue[@]}" | sort)

  # Process
  local -a result=()
  while [[ "${#queue[@]}" -gt 0 ]]; do
    local node="${queue[0]}"
    queue=("${queue[@]:1}")
    result+=("$node")

    for neighbor in ${adj[$node]}; do
      indegree["$neighbor"]=$(( indegree[$neighbor] - 1 ))
      if [[ "${indegree[$neighbor]}" -eq 0 ]]; then
        queue+=("$neighbor")
        mapfile -t queue < <(printf '%s\n' "${queue[@]}" | sort)
      fi
    done
  done

  # Cycle detection — if any services were not added to result, they're in a cycle
  if [[ "${#result[@]}" -ne "${#services[@]}" ]]; then
    local -a cycled=()
    for s in "${services[@]}"; do
      local in_result=false
      for r in "${result[@]}"; do [[ "$s" == "$r" ]] && in_result=true && break; done
      $in_result || cycled+=("$s")
    done

    echo "" >&2
    echo -e "  ${RED}${BOLD}✗  Circular dependency detected in scripts/services.dep!${NC}" >&2
    echo -e "  ${DIM}The following services form a cycle and cannot be started:${NC}" >&2
    for s in "${cycled[@]}"; do
      echo -e "    ${RED}• $s${NC}  ${DIM}(depends on: ${DEPS[$s]:-nothing})${NC}" >&2
    done
    echo "" >&2
    echo -e "  Open ${BOLD}scripts/services.dep${NC} and fix the cycle." >&2
    echo "" >&2
    exit 1
  fi

  printf '%s\n' "${result[@]}"
}

# =============================================================================
# Initialise — run at startup
# =============================================================================
_init() {
  _discover
  _load_deps

  if [[ "${#SERVICES[@]}" -eq 0 ]]; then
    error "No compose.yml files found under $HOMELAB_DIR"
  fi

  # Build the full boot order via topo sort
  mapfile -t BOOT_ORDER < <(_topo_sort "${!SERVICES[@]}")
}

# =============================================================================
# Helpers
# =============================================================================

_compose() {
  local service="$1"; shift
  docker compose -f "$HOMELAB_DIR/${SERVICES[$service]}" "$@"
}

_validate() {
  for s in "$@"; do
    [[ -n "${SERVICES[$s]+_}" ]] || error "Unknown service: '$s'. Run 'make list' to see valid names."
  done
}

# Returns services from BOOT_ORDER that match the given list, preserving order
_ordered() {
  local -a wanted=("$@")
  for s in "${BOOT_ORDER[@]}"; do
    for w in "${wanted[@]}"; do
      [[ "$s" == "$w" ]] && echo "$s" && break
    done
  done
}

# Returns one of: running | partial | exited | missing
_health() {
  local service="$1"
  local compose_file="$HOMELAB_DIR/${SERVICES[$service]}"

  local expected
  expected=$(docker compose -f "$compose_file" config --services 2>/dev/null | wc -l)

  local running
  running=$(docker compose -f "$compose_file" ps --status running -q 2>/dev/null | wc -l)

  local total
  total=$(docker compose -f "$compose_file" ps -a -q 2>/dev/null | wc -l)

  if   [[ "$total"   -eq 0 ]];                         then echo "missing"
  elif [[ "$running" -eq "$expected" && "$expected" -gt 0 ]]; then echo "running"
  elif [[ "$running" -gt 0 ]];                         then echo "partial"
  else                                                       echo "exited"
  fi
}

# =============================================================================
# Smart start — checks state before doing anything
# =============================================================================
_start_service() {
  local s="$1"
  local health
  health=$(_health "$s")

  case "$health" in
    running)
      echo ""
      echo -e "  ${YELLOW}${BOLD}⚠  $s is already running.${NC}"
      echo -ne "  Recreate it? This will briefly stop the container. [y/N]: "
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        step "recreating $s..."
        _compose "$s" up -d --force-recreate 2>&1 | grep -E "Started|Running|Created|Warning|Error" | sed 's/^/     /' || true
        info "$s recreated"
      else
        info "$s skipped"
      fi
      ;;

    exited)
      echo ""
      echo -e "  ${YELLOW}${BOLD}⚠  $s exists but is stopped.${NC}"
      echo -ne "  Start it? [y/N]: "
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        step "starting $s..."
        _compose "$s" start 2>&1 | grep -E "Started|Warning|Error" | sed 's/^/     /' || true
        info "$s started"
      else
        info "$s skipped"
      fi
      ;;

    partial)
      echo ""
      echo -e "  ${YELLOW}${BOLD}⚠  $s is partially running (some containers are down).${NC}"
      echo -ne "  Recreate the whole service? [y/N]: "
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        step "recreating $s..."
        _compose "$s" up -d --force-recreate 2>&1 | grep -E "Started|Running|Created|Warning|Error" | sed 's/^/     /' || true
        info "$s recreated"
      else
        step "starting missing containers for $s..."
        _compose "$s" up -d 2>&1 | grep -E "Started|Running|Created|Warning|Error" | sed 's/^/     /' || true
        info "$s partially recovered"
      fi
      ;;

    missing)
      step "creating $s..."
      _compose "$s" up -d 2>&1 | grep -E "Started|Running|Created|Warning|Error" | sed 's/^/     /' || true
      info "$s started"
      ;;
  esac
}

# =============================================================================
# Commands
# =============================================================================

cmd_up() {
  local -a targets
  if [[ "$#" -eq 0 ]]; then
    targets=("${BOOT_ORDER[@]}")
    header "Starting all services"
  else
    _validate "$@"
    mapfile -t targets < <(_ordered "$@")
    header "Starting: ${targets[*]}"
  fi

  for s in "${targets[@]}"; do
    _start_service "$s"
  done

  echo ""
  info "Done. Run 'make status' to verify."
}

cmd_down() {
  local -a targets

  if [[ "$#" -eq 0 ]]; then
    mapfile -t targets < <(printf '%s\n' "${BOOT_ORDER[@]}" | tac)
    echo ""
    echo -e "  ${RED}${BOLD}⚠  WARNING: This will stop ALL running services.${NC}"
    echo -e "  ${DIM}This includes vpn — you will lose remote/SSH access if connected via Tailscale.${NC}"
  else
    _validate "$@"
    mapfile -t targets < <(_ordered "$@" | tac)
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  WARNING: This will stop: ${targets[*]}${NC}"
    if [[ " ${targets[*]} " == *" vpn "* ]]; then
      echo -e "  ${RED}${DIM}vpn is in the list — you will lose remote/SSH access if connected via Tailscale.${NC}"
    fi
  fi

  echo ""
  echo -ne "  Type ${BOLD}yes${NC} to continue: "
  read -r confirm
  [[ "$confirm" != "yes" ]] && { echo -e "\n  Aborted."; exit 0; }

  if [[ "$#" -eq 0 ]]; then
    header "Stopping all services"
  else
    header "Stopping: ${targets[*]}"
  fi

  for s in "${targets[@]}"; do
    step "$s"
    _compose "$s" down 2>&1 | grep -E "Stopped|Removed|Warning|Error" | sed 's/^/     /' || true
  done

  echo ""
  info "Done."
}

cmd_restart() {
  [[ "$#" -eq 0 ]] && error "Usage: make <service>-restart"
  _validate "$@"

  header "Restarting: $*"
  for s in "$@"; do
    step "restarting $s..."
    _compose "$s" up -d --force-recreate 2>&1 | grep -E "Started|Running|Created|Recreated|Warning|Error" | sed 's/^/     /' || true
    info "$s restarted"
  done
}

# ------------------------------------------------------------------------------
# remove — Stop and remove containers but keep files on disk
# ------------------------------------------------------------------------------
cmd_remove() {
  [[ "$#" -eq 0 ]] && error "Usage: make <service>-remove"
  _validate "$@"

  for s in "$@"; do
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  This will stop and remove all containers for: $s${NC}"
    echo -e "  ${DIM}Config, data, and compose files are kept on disk.${NC}"
    echo ""
    echo -ne "  Type ${BOLD}yes${NC} to continue: "
    read -r confirm
    [[ "$confirm" != "yes" ]] && { info "$s skipped"; continue; }

    step "removing $s..."
    _compose "$s" down 2>&1 | grep -E "Stopped|Removed|Warning|Error" | sed 's/^/     /' || true
    info "$s containers removed. Files kept at: ${SERVICES[$s]%/compose.yml}"
  done
}

# ------------------------------------------------------------------------------
# delete — Stop containers AND delete the entire service directory from disk
# ------------------------------------------------------------------------------
cmd_delete() {
  [[ "$#" -eq 0 ]] && error "Usage: make <service>-delete"
  _validate "$@"

  for s in "$@"; do
    local service_dir="$HOMELAB_DIR/${SERVICES[$s]%/compose.yml}"

    echo ""
    echo -e "  ${RED}${BOLD}⚠  DANGER: This will permanently delete: $s${NC}"
    echo -e "  ${RED}Directory: $service_dir${NC}"
    echo -e "  ${DIM}All containers, config, and data will be destroyed. This cannot be undone.${NC}"
    echo ""
    echo -ne "  Type the service name ${BOLD}$s${NC} to confirm: "
    read -r confirm
    [[ "$confirm" != "$s" ]] && { info "$s skipped"; continue; }

    step "stopping containers for $s..."
    _compose "$s" down 2>&1 | grep -E "Stopped|Removed|Warning|Error" | sed 's/^/     /' || true

    step "deleting $service_dir..."
    sudo rm -rf "$service_dir"
    info "$s deleted."

    # Remove from services.dep if it has an entry
    if grep -q "^${s}[[:space:]]*->" "$DEPS_FILE" 2>/dev/null; then
      sed -i "/^${s}[[:space:]]*->/d" "$DEPS_FILE"
      info "Removed $s from services.dep"
    fi
  done

  echo ""
  warn "If $s was a dependency for other services, update scripts/services.dep manually."
}

cmd_status() {
  header "Homelab Status"

  printf "  ${BOLD}%-22s %-12s %s${NC}\n" "SERVICE" "HEALTH" "CONTAINERS"
  printf "  ${DIM}%-22s %-12s %s${NC}\n"  "───────────────────" "──────────" "──────────────────────────────"

  local all_healthy=true

  for s in "${BOOT_ORDER[@]}"; do
    local health
    health=$(_health "$s")

    local color label
    case "$health" in
      running)  color="$GREEN";  label="● running"  ;;
      partial)  color="$YELLOW"; label="◑ partial"  ; all_healthy=false ;;
      exited)   color="$RED";    label="○ exited"   ; all_healthy=false ;;
      missing)  color="$YELLOW"; label="- missing"  ; all_healthy=false ;;
    esac

    local containers
    containers=$(
      docker compose -f "$HOMELAB_DIR/${SERVICES[$s]}" ps -a \
        --format "{{.Name}}({{.State}})" 2>/dev/null \
        | tr '\n' '  ' | sed 's/  $//'
    )
    [[ -z "$containers" ]] && containers="${DIM}none${NC}"

    printf "  %-22s ${color}%-12s${NC} %b\n" "$s" "$label" "$containers"
  done

  echo ""
  if $all_healthy; then
    info "All services running."
  else
    warn "Some services are not healthy. Run 'make heal' to fix."
  fi
}

cmd_heal() {
  header "Healing unhealthy services"

  local healed=0

  for s in "${BOOT_ORDER[@]}"; do
    local health
    health=$(_health "$s")

    case "$health" in
      running)
        info "$s ${DIM}(healthy)${NC}"
        ;;
      partial|exited|missing)
        warn "$s is ${health} — starting..."
        _compose "$s" up -d 2>&1 | grep -E "Started|Created|Running|Warning|Error" | sed 's/^/     /' || true
        healed=$((healed + 1))
        ;;
    esac
  done

  echo ""
  if [[ "$healed" -eq 0 ]]; then
    info "Nothing to heal — all services are healthy."
  else
    info "Healed $healed service(s). Run 'make status' to verify."
  fi
}

cmd_logs() {
  [[ "$#" -eq 0 ]] && error "Usage: make <service>-logs"
  local service="$1"; shift
  _validate "$service"
  echo -e "\n${DIM}Logs for: $service${NC}\n"
  _compose "$service" logs "$@"
}

cmd_pull() {
  local -a targets
  if [[ "$#" -eq 0 ]]; then
    targets=("${BOOT_ORDER[@]}")
    header "Pulling latest images for all services"
  else
    _validate "$@"
    targets=("$@")
    header "Pulling: ${targets[*]}"
  fi

  for s in "${targets[@]}"; do
    step "pulling $s..."
    _compose "$s" pull
  done

  echo ""
  info "Images updated. Restart with: make <service>-restart"
}

cmd_list() {
  header "Registered services  ${DIM}(boot order)${NC}"
  {
    echo "NAME|COMPOSE FILE|DEPENDS ON"
    echo "────|────────────|──────────"
    for s in "${BOOT_ORDER[@]}"; do
      local deps="${DEPS[$s]:-—}"
      echo "$s|${SERVICES[$s]}|$deps"
    done
  } | column -t -s '|' | sed 's/^/  /'
  echo ""
}

# =============================================================================
# Usage
# =============================================================================

usage() {
  cat <<EOF

${BOLD}Homelab Service Manager${NC}

${BOLD}GLOBAL COMMANDS${NC}
  ${CYAN}make up${NC}                    Start all services (auto boot order)
  ${CYAN}make down${NC}                  Stop all services (warns first)
  ${CYAN}make status${NC}                Health table for all services
  ${CYAN}make heal${NC}                  Start any crashed or missing services
  ${CYAN}make list${NC}                  List all services with deps and boot order

${BOLD}PER-SERVICE COMMANDS${NC}
  ${CYAN}make <service>${NC}             Start service (resolves deps automatically)
  ${CYAN}make <service>-down${NC}        Stop service
  ${CYAN}make <service>-restart${NC}     Restart service (recreates container)
  ${CYAN}make <service>-logs${NC}        Follow logs (ctrl+c to exit)
  ${CYAN}make <service>-pull${NC}        Pull latest image
  ${CYAN}make <service>-remove${NC}      Stop and remove containers (keep files)
  ${CYAN}make <service>-delete${NC}      Remove containers AND delete service directory

${BOLD}ADDING A SERVICE${NC}
  1. Create the compose.yml anywhere under homelab/
  2. If it has dependencies, add one line to scripts/services.dep:
       myservice -> dep1 dep2
  3. That's it. It is auto-discovered on next run.

${BOLD}EXAMPLES${NC}
  make up
  make down
  make ollama
  make ollama-down
  make ollama-restart
  make ollama-logs
  make open-webui          # starts ollama first (dep), then open-webui
  make dns                 # starts vpn first (dep), then dns
  make status
  make heal

EOF
}

# =============================================================================
# Entry point
# =============================================================================

# Boot order is populated here — BOOT_ORDER is used by all commands
declare -a BOOT_ORDER=()
_init

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$COMMAND" in
  up)      cmd_up "$@"      ;;
  down)    cmd_down "$@"    ;;
  restart) cmd_restart "$@" ;;
  remove)  cmd_remove "$@"  ;;
  delete)  cmd_delete "$@"  ;;
  status)  cmd_status       ;;
  heal)    cmd_heal         ;;
  logs)    cmd_logs "$@"    ;;
  pull)    cmd_pull "$@"    ;;
  list)    cmd_list         ;;
  help|--help|-h) usage     ;;
  *) error "Unknown command: '$COMMAND'. Run 'make help'" ;;
esac
