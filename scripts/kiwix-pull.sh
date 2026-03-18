#!/usr/bin/env bash
# =============================================================================
# scripts/kiwix-pull.sh — Download ZIM files from Kiwix
# =============================================================================
#
# USAGE:
#   ./scripts/kiwix-pull.sh <category> [category2 ...]
#   ./scripts/kiwix-pull.sh --list
#   ./scripts/kiwix-pull.sh --browse <category>
#   ./scripts/kiwix-pull.sh --file <filename> <category>
#
# OPTIONS:
#   --list            List all available categories on the Kiwix server
#   --browse CAT      List all files in a category (supports --lang filter)
#   --file NAME CAT   Download one exact file by name
#   --lang CODE       Language code to filter by (default: en)
#   --dest DIR        Destination directory (default: services/kiwix/data)
#   --dry-run         Show what would be downloaded without downloading
#   --all-lang        Download all languages (overrides --lang)
#
# EXAMPLES:
#   ./scripts/kiwix-pull.sh devdocs
#   ./scripts/kiwix-pull.sh --lang de wikipedia
#   ./scripts/kiwix-pull.sh --browse freecodecamp
#   ./scripts/kiwix-pull.sh --browse wikipedia --lang fr
#   ./scripts/kiwix-pull.sh --file wikipedia_en_all_2026-02.zim wikipedia
#   ./scripts/kiwix-pull.sh --dry-run devdocs freecodecamp
#
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

BASE_URL="https://download.kiwix.org/zim"
HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DEST="$HOMELAB_DIR/services/kiwix/data"
DEFAULT_LANG="en"

# ── Colors ────────────────────────────────────────────────────────────────────

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────

info()    { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "  ${RED}✘${NC}  $*" >&2; exit 1; }
step()    { echo -e "  ${CYAN}→${NC}  $*"; }
header()  { echo -e "\n  ${BOLD}$*${NC}\n"; }
dim()     { echo -e "  ${DIM}$*${NC}"; }

# ── List all categories ───────────────────────────────────────────────────────

cmd_list() {
  header "Available Kiwix categories"
  step "Fetching index from $BASE_URL ..."
  echo ""

  local index_raw
  index_raw=$(wget -qO- "$BASE_URL/") || error "Failed to fetch $BASE_URL"

  local categories
  categories=$(echo "$index_raw" | grep -oP '(?<=href=")[a-zA-Z0-9_-]+(?=/)' | sort) || true

  if [[ -z "$categories" ]]; then
    error "Could not parse category list from $BASE_URL"
  fi

  while IFS= read -r cat; do
    printf "  ${CYAN}%-30s${NC} %s/%s/\n" "$cat" "$BASE_URL" "$cat"
  done <<< "$categories"

  echo ""
}

# ── List files in a category ──────────────────────────────────────────────────

fetch_index() {
  local category="$1"
  local url="$BASE_URL/$category/"
  wget -qO- "$url" \
    | grep -oP 'href="[^"]+\.zim"' \
    | grep -oP '"[^"]+"' \
    | tr -d '"'
}

# ── Parse series name (filename without date) ─────────────────────────────────
# e.g. freecodecamp_en_all_2026-02.zim → freecodecamp_en_all

get_series() {
  local filename="$1"
  # Strip trailing _YYYY-MM.zim
  echo "$filename" | sed -E 's/_[0-9]{4}-[0-9]{2}\.zim$//'
}

# ── Get date from filename ────────────────────────────────────────────────────
# e.g. freecodecamp_en_all_2026-02.zim → 2026-02

get_date() {
  local filename="$1"
  echo "$filename" | grep -oP '[0-9]{4}-[0-9]{2}(?=\.zim$)'
}

# ── Atomic download helper ────────────────────────────────────────────────────
# Downloads to a .tmp file, moves to final path on success.
# Keeps .tmp on interrupt so next run resumes. Cleans up only on failure.

_download() {
  local url="$1"
  local dest_file="$2"
  local tmp_file="${dest_file}.tmp"
  local exit_code=0

  wget -c -q --show-progress -O "$tmp_file" "$url" || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    mv "$tmp_file" "$dest_file"
    return 0
  elif [[ $exit_code -eq 130 ]]; then
    # Ctrl+C — keep .tmp for resuming
    echo ""
    warn "Interrupted — run the same command again to resume."
    exit 1
  else
    # Real failure — discard partial
    rm -f "$tmp_file"
    return 1
  fi
}

# ── Download a category ───────────────────────────────────────────────────────

# ── Download a single exact file ─────────────────────────────────────────────

# ── Browse files in a category ────────────────────────────────────────────────

cmd_browse() {
  local category="$1"
  local lang="$2"
  local all_lang="$3"
  local url="$BASE_URL/$category/"

  header "Browsing: $category"
  step "Fetching file list from $url ..."

  local index_raw
  index_raw=$(wget -qO- "$url") || error "Failed to fetch index for '$category'."

  local all_files
  all_files=$(echo "$index_raw" | grep -oP 'href="[^"]+\.zim"' | grep -oP '"[^"]+"' | tr -d '"')

  if [[ -z "$all_files" ]]; then
    error "No .zim files found at $url"
  fi

  local filtered
  if [[ "$all_lang" == "true" ]]; then
    filtered="$all_files"
  else
    filtered=$(echo "$all_files" | grep -E "_${lang}_") || true
    if [[ -z "$filtered" ]]; then
      warn "No files for language '$lang'. Available languages:"
      echo "$all_files" | grep -oP '(?<=_)[a-z]{2,3}(?=_)' | sort -u | while read -r l; do
        echo "        $l"
      done
      return
    fi
  fi

  echo ""
  printf "  ${BOLD}%-65s %s${NC}
" "FILENAME" "SIZE"
  printf "  ${DIM}%-65s %s${NC}
"  "────────────────────────────────────────────────────────────────" "──────"

  while IFS= read -r f; do
    local size
    size=$(echo "$index_raw" | grep -oP "(?<=>$f<)[^<]*" | grep -oP '[0-9.]+\s*[KMG]' | head -1 || echo "?")
    [[ -z "$size" ]] && size=$(echo "$index_raw" | grep "$f" | grep -oP '[0-9]+\.?[0-9]*[KMG]' | head -1 || echo "?")
    printf "  %-65s ${DIM}%s${NC}
" "$f" "$size"
  done <<< "$filtered"

  echo ""
  dim "To download a specific file:"
  echo -e "  ${BOLD}./scripts/kiwix-pull.sh --file <filename> $category${NC}"
  echo ""
}

# ── Download one exact file ───────────────────────────────────────────────────

cmd_pull_file() {
  local input="$1"
  local category="$2"
  local dest="$3"
  local dry_run="$4"

  local url filename

  # Accept either a full URL or a filename + category
  if [[ "$input" == http* ]]; then
    url="$input"
    filename="${input##*/}"
    if [[ -z "$category" ]]; then
      category=$(echo "$input" | grep -oP '(?<=/zim/)[^/]+')
    fi
  else
    [[ -z "$category" ]] && error "--file requires a category when not using a full URL.
  Usage: --file <filename> <category>
  Usage: --file <full-url>"
    filename="$input"
    url="$BASE_URL/$category/$filename"
  fi

  header "Kiwix pull: $filename"

  local target="$dest/$filename"

  if [[ -f "$target" ]]; then
    info "Already exists: $target"
    return
  fi

  dim "URL:         $url"
  dim "Destination: $dest"
  echo ""

  if [[ "$dry_run" == "true" ]]; then
    warn "Dry run — nothing downloaded."
    return
  fi

  echo -ne "  Download ${BOLD}$filename${NC}? [y/N] "
  read -r confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Aborted."; return; }

  mkdir -p "$dest"

  if [[ -f "${target}.tmp" ]]; then
    step "Resuming partial download..."
  else
    step "Downloading..."
  fi

  if _download "$url" "$target"; then
    info "$filename downloaded"
    echo ""
    step "Restart Kiwix to load the new file:"
    echo -e "       ${BOLD}make kiwix-restart${NC}"
    echo ""
  else
    error "Download failed."
  fi
}

cmd_pull() {
  local category="$1"
  local lang="$2"
  local dest="$3"
  local dry_run="$4"
  local all_lang="$5"

  local url="$BASE_URL/$category/"

  header "Kiwix pull: $category"
  step "Fetching file list from $url ..."

  # Single fetch — reused for both filenames and sizes
  local index_raw
  index_raw=$(wget -qO- "$url") || error "Failed to fetch index for '$category'. Check the category name with --list."

  local all_files
  all_files=$(echo "$index_raw" | grep -oP 'href="[^"]+\.zim"' | grep -oP '"[^"]+"' | tr -d '"')

  if [[ -z "$all_files" ]]; then
    error "No .zim files found at $url"
  fi

  # Filter by language
  local filtered
  if [[ "$all_lang" == "true" ]]; then
    filtered="$all_files"
  else
    filtered=$(echo "$all_files" | grep -E "_${lang}_") || true
    if [[ -z "$filtered" ]]; then
      warn "No files found for language '$lang' in '$category'."
      warn "Available languages:"
      echo "$all_files" | grep -oP '(?<=_)[a-z]{2}(?=_)' | sort -u | while read -r l; do
        echo "        $l"
      done
      return
    fi
  fi

  # For each unique series, find the latest date
  declare -A latest_file
  declare -A latest_date

  while IFS= read -r filename; do
    local series date
    series=$(get_series "$filename")
    date=$(get_date "$filename") || continue
    [[ -z "$date" ]] && continue

    if [[ -z "${latest_date[$series]+x}" ]] || [[ "$date" > "${latest_date[$series]}" ]]; then
      latest_date[$series]="$date"
      latest_file[$series]="$filename"
    fi
  done <<< "$filtered"

  if [[ ${#latest_file[@]} -eq 0 ]]; then
    error "No downloadable files found after filtering."
  fi

  echo ""
  step "Latest files to download (${#latest_file[@]} total):"
  echo ""
  for series in $(echo "${!latest_file[@]}" | tr ' ' '\n' | sort); do
    local f="${latest_file[$series]}"
    local size
    size=$(echo "$index_raw" | grep -oP "(?<=>$f<)[^<]*" | grep -oP '[0-9]+\.?[0-9]*[KMG]' | head -1 || echo "")
    [[ -z "$size" ]] && size=$(echo "$index_raw" | grep "$f" | grep -oP '[0-9]+\.?[0-9]*[KMG]' | head -1 || echo "?")
    printf "  ${DIM}%-60s${NC} %s\n" "$f" "$size"
  done
  echo ""

  if [[ "$dry_run" == "true" ]]; then
    warn "Dry run — nothing downloaded."
    return
  fi

  # Confirm
  echo -ne "  Download ${BOLD}${#latest_file[@]}${NC} file(s) to ${BOLD}$dest${NC}? [y/N] "
  read -r confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Aborted."; return; }
  echo ""

  mkdir -p "$dest"

  local success=0 skipped=0 failed=0
  for series in $(echo "${!latest_file[@]}" | tr ' ' '\n' | sort); do
    local filename="${latest_file[$series]}"
    local target="$dest/$filename"

    # Remove older versions of the same series (skip if it's the target file itself)
    local old_files
    old_files=$(find "$dest" -name "${series}_*.zim" ! -name "$filename" 2>/dev/null) || true
    if [[ -n "$old_files" ]]; then
      echo "$old_files" | while read -r old; do
        warn "Removing old version: $(basename "$old")"
        rm -f "$old"
      done
    fi

    if [[ -f "${target}.tmp" ]]; then
      step "Resuming: $filename ..."
    else
      step "Downloading $filename ..."
    fi
    if _download "$BASE_URL/$category/$filename" "$target"; then
      info "$filename downloaded"
      (( success++ )) || true
    else
      warn "Failed: $filename"
      (( failed++ )) || true
    fi
  done

  echo ""
  header "Summary: $category"
  [[ $success -gt 0 ]] && info "$success file(s) downloaded"
  [[ $skipped -gt 0 ]] && dim "$skipped file(s) already up to date"
  [[ $failed  -gt 0 ]] && warn "$failed file(s) failed"

  if [[ $success -gt 0 ]]; then
    echo ""
    step "Restart Kiwix to load new files:"
    echo -e "       ${BOLD}make kiwix-restart${NC}"
    echo ""
  fi
}

# ── Entry point ───────────────────────────────────────────────────────────────

LANG_FILTER="$DEFAULT_LANG"
DEST="$DEFAULT_DEST"
DRY_RUN="false"
ALL_LANG="false"
EXACT_FILE=""
BROWSE_CAT=""
CATEGORIES=()

usage() {
  echo ""
  echo -e "  ${BOLD}Usage:${NC} ./scripts/kiwix-pull.sh [options] <category> [category2 ...]"
  echo ""
  echo -e "  ${BOLD}Options:${NC}"
  echo "    --list              List all available categories"
  echo "    --browse <cat>      List files in a category (use with --lang to filter)"
  echo "    --file <name> <cat> Download one exact file by name"
  echo "    --lang <code>       Language code to filter (default: en)"
  echo "    --all-lang          Download all languages (overrides --lang)"
  echo "    --dest <dir>        Destination directory (default: services/kiwix/data)"
  echo "    --dry-run           Preview without downloading"
  echo ""
  echo -e "  ${BOLD}Examples:${NC}"
  echo "    ./scripts/kiwix-pull.sh devdocs"
  echo "    ./scripts/kiwix-pull.sh freecodecamp stack_exchange"
  echo "    ./scripts/kiwix-pull.sh --lang de wikipedia"
  echo "    ./scripts/kiwix-pull.sh --browse wikipedia"
  echo "    ./scripts/kiwix-pull.sh --browse wikipedia --lang fr"
  echo "    ./scripts/kiwix-pull.sh --file wikipedia_en_all_2026-02.zim wikipedia"
  echo "    ./scripts/kiwix-pull.sh --file https://download.kiwix.org/zim/other/archlinux_en_all_maxi_2025-09.zim"
  echo "    ./scripts/kiwix-pull.sh --dry-run devdocs"
  echo "    ./scripts/kiwix-pull.sh --list"
  echo ""
  exit 0
}

[[ "$#" -eq 0 ]] && usage

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --list)     cmd_list; exit 0 ;;
    --browse)   BROWSE_CAT="$2"; shift 2 ;;
    --lang)     LANG_FILTER="$2"; shift 2 ;;
    --dest)     DEST="$2"; shift 2 ;;
    --dry-run)  DRY_RUN="true"; shift ;;
    --all-lang) ALL_LANG="true"; shift ;;
    --file)     EXACT_FILE="$2"; shift 2 ;;
    --help|-h)  usage ;;
    --*)        error "Unknown option: $1" ;;
    *)          CATEGORIES+=("$1"); shift ;;
  esac
done

# ── Dispatch ──────────────────────────────────────────────────────────────────

if [[ -n "$BROWSE_CAT" ]]; then
  cmd_browse "$BROWSE_CAT" "$LANG_FILTER" "$ALL_LANG"
  exit 0
fi

if [[ -n "$EXACT_FILE" ]]; then
  # Full URL needs no category; filename mode requires one
  if [[ "$EXACT_FILE" != http* ]] && [[ ${#CATEGORIES[@]} -ne 1 ]]; then
    error "--file with a filename requires exactly one category.
  Usage: --file <filename> <category>
  Or:    --file <full-url>"
  fi
  category="${CATEGORIES[0]:-}"
  cmd_pull_file "$EXACT_FILE" "$category" "$DEST" "$DRY_RUN"
  exit 0
fi

[[ ${#CATEGORIES[@]} -eq 0 ]] && error "No category specified. Run with --list to see available categories."

for cat in "${CATEGORIES[@]}"; do
  cmd_pull "$cat" "$LANG_FILTER" "$DEST" "$DRY_RUN" "$ALL_LANG"
done
