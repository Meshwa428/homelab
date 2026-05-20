#!/bin/bash
# =============================================================================
# hf-pull.sh — HuggingFace Model Puller & llama-swap Auto-Registrar
# =============================================================================
# Downloads a model from Hugging Face directly into a flat files folder
# (services/llama-swap/models/) and automatically registers the exact
# path in config.yaml.
#
# USAGE:
#   ./scripts/hf-pull.sh <repo_id[:quant]> [model_key]
#
# EXAMPLES:
#   ./scripts/hf-pull.sh openbmb/MiniCPM-V-4.6-Thinking-gguf:Q4_K_M
#   ./scripts/hf-pull.sh bartowski/Mistral-7B-Instruct-v0.3-GGUF:Q5_K_M mistral
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$HOMELAB_DIR/services/llama-swap/config.yaml"
MODELS_DIR="$HOMELAB_DIR/services/llama-swap/models"

# --- Parse HF_TOKEN from shared/.env if present -------------------------------
HF_TOKEN=""
if [[ -f "$HOMELAB_DIR/shared/.env" ]]; then
  HF_TOKEN=$(grep -E "^HF_TOKEN=" "$HOMELAB_DIR/shared/.env" | cut -d'=' -f2- | sed "s/^[ '\"\t]*//;s/[ '\"\t]*$//" || true)
fi

# --- Colors ------------------------------------------------------------------
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

info()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}!${NC}  $*"; }
error()  { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }
step()   { echo -e "  ${CYAN}→${NC}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}$*${NC}\n"; }

usage() {
  cat <<EOF

${BOLD}hf-pull.sh${NC} — Download & register a GGUF model from Hugging Face

${BOLD}USAGE${NC}
  ./scripts/hf-pull.sh <repo_id[:quant]> [model_key]

${BOLD}ARGUMENTS${NC}
  repo_id[:quant]   HuggingFace repo and optional quantization tag (e.g., Q4_K_M)
                    Defaults to Q4_K_M if omitted
  model_key         Key to register in llama-swap config (auto-derived if omitted)

${BOLD}EXAMPLES${NC}
  ./scripts/hf-pull.sh openbmb/MiniCPM-V-4.6-Thinking-gguf:Q4_K_M
  ./scripts/hf-pull.sh bartowski/Mistral-7B-Instruct-v0.3-GGUF:Q5_K_M mistral

EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

HF_REF="$1"
MODEL_KEY="${2:-}"

# Parse repo and quant
REPO_ID="${HF_REF%%:*}"
QUANT="${HF_REF#*:}"
if [[ "$QUANT" == "$HF_REF" ]]; then
  QUANT="Q4_K_M"
fi

docker --version >/dev/null 2>&1 || error "Docker is required but not found."
mkdir -p "$MODELS_DIR"
[[ -f "$CONFIG_FILE" ]] || echo "models:" > "$CONFIG_FILE"

# --- Derive model key if not provided ---------------------------------------
if [[ -z "$MODEL_KEY" ]]; then
  MODEL_KEY="${REPO_ID}:${QUANT,,}"
fi

# --- Run the downloader inside python container -----------------------------
header "Downloading from Hugging Face"
step "Repo:  ${BOLD}${REPO_ID}${NC}"
step "Quant: ${BOLD}${QUANT}${NC}"
step "Key:   ${BOLD}${MODEL_KEY}${NC}"
echo ""

# We use huggingface_hub inside Python with hf_transfer enabled for maximum speed.
# It downloads files directly into the mounted /models/<model_key> folder.
# Sanitize the container name by replacing slashes and colons with underscores to satisfy Docker rules
SAFE_KEY=$(echo "${MODEL_KEY}" | sed 's|[/:]|_|g')
docker rm -f "hf-puller-${SAFE_KEY}" >/dev/null 2>&1 || true

ENV_ARGS=()
if [[ -n "$HF_TOKEN" ]]; then
  ENV_ARGS+=("-e" "HF_TOKEN=$HF_TOKEN")
fi

DOWNLOAD_OUT=$(docker run --rm \
  --name "hf-puller-${SAFE_KEY}" \
  -v "$MODELS_DIR:/models" \
  -e HF_HUB_ENABLE_HF_TRANSFER=1 \
  -e HF_HOME=/models/.cache \
  "${ENV_ARGS[@]}" \
  -e PYTHONUNBUFFERED=1 \
  python:3.10-slim \
  sh -c "pip install -q huggingface_hub hf_transfer && \
         python3 -u -c \"
import os, sys
from huggingface_hub import hf_hub_download, list_repo_files

repo = '$REPO_ID'
quant = '$QUANT'.lower()
model_key = '$MODEL_KEY'

try:
    files = list_repo_files(repo)
except Exception as e:
    print(f'ERROR: Failed to list files for repo {repo}: {e}', file=sys.stderr)
    sys.exit(1)

gguf_files = [f for f in files if f.lower().endswith('.gguf')]
matching = [f for f in gguf_files if quant in f.lower()]

if not matching:
    # Fallback to first GGUF file if no exact quant found
    if gguf_files:
        matching = [gguf_files[0]]
    else:
        print(f'ERROR: No GGUF files found in repo {repo}', file=sys.stderr)
        sys.exit(1)

target_file = matching[0]
print(f'Found target file: {target_file}')
print('Starting download...')

try:
    path = hf_hub_download(
        repo_id=repo,
        filename=target_file,
        local_dir=f'/models/{repo}',
        local_dir_use_symlinks=False
    )
    print(f'DOWNLOAD_SUCCESS:{os.path.basename(path)}')
except Exception as e:
    print(f'ERROR: Download failed: {e}', file=sys.stderr)
    sys.exit(1)
\"")

# Parse output
echo "$DOWNLOAD_OUT"

FILENAME=$(echo "$DOWNLOAD_OUT" | grep "DOWNLOAD_SUCCESS:" | cut -d':' -f2 || true)

if [[ -z "$FILENAME" ]]; then
  error "Download failed or target file could not be determined."
fi

# --- Ensure config has models: root -----------------------------------------
if ! grep -q "^models:" "$CONFIG_FILE" 2>/dev/null; then
  echo "models:" >> "$CONFIG_FILE"
fi

# --- Remove existing block for this key if present --------------------------
if grep -q "^  ${MODEL_KEY}:" "$CONFIG_FILE" 2>/dev/null || grep -q "^  \"${MODEL_KEY}\":" "$CONFIG_FILE" 2>/dev/null; then
  warn "Key '${MODEL_KEY}' already exists — overwriting..."
  python3 - "$CONFIG_FILE" "$MODEL_KEY" <<'PYEOF'
import sys, re
config_path, key = sys.argv[1], sys.argv[2]
with open(config_path) as f:
    lines = f.readlines()
out, skip = [], False
for line in lines:
    if re.match(rf'^  "{re.escape(key)}":\s*$', line) or re.match(rf'^  {re.escape(key)}:\s*$', line):
        skip = True
    elif skip and re.match(r'^  \S', line):
        skip = False
    if not skip:
        out.append(line)
with open(config_path, 'w') as f:
    f.writelines(out)
PYEOF
fi

# --- Append new model block -------------------------------------------------
cat <<EOF >> "$CONFIG_FILE"
  "${MODEL_KEY}":
    cmd: "llama-server --port \${PORT} --model /models/${REPO_ID}/${FILENAME} -c 2048 --threads 4"
    proxy: "http://127.0.0.1:\${PORT}"
    ttl: 300
EOF

echo ""
info "Registered ${BOLD}${MODEL_KEY}${NC} in services/llama-swap/config.yaml"
echo ""

# --- Auto-Restart llama-swap ------------------------------------------------
header "Service Synchronization"

check_idle() {
  local is_running
  is_running=$(docker inspect -f '{{.State.Running}}' llama-swap 2>/dev/null || echo "false")
  if [[ "$is_running" != "true" ]]; then
    return 0
  fi

  local json
  json=$(docker exec llama-swap curl -s http://localhost:8080/running 2>/dev/null || \
         docker exec llama-swap wget -qO- http://localhost:8080/running 2>/dev/null || \
         echo "")

  if [[ -z "$json" ]]; then
    return 0
  fi

  if python3 -c "import sys, json; data=json.loads(sys.argv[1]); sys.exit(0 if len(data.get('running', [])) == 0 else 1)" "$json" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

if check_idle; then
  info "llama-swap is idle. Restarting immediately to apply changes..."
  "$HOMELAB_DIR/lab" restart llama-swap
else
  warn "llama-swap is currently active (serving models or processing requests)."
  step "Waiting for llama-swap to become idle before restarting..."
  while ! check_idle; do
    sleep 5
  done
  info "llama-swap is now idle. Restarting..."
  "$HOMELAB_DIR/lab" restart llama-swap
fi

