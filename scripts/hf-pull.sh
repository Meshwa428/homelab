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
  # Adapt command name depending on whether we're called via ./lab or directly
  if [[ -n "${LAB_INVOKED:-}" ]]; then
    local CMD="./lab model pull"
  else
    local CMD="./scripts/hf-pull.sh"
  fi

  cat <<EOF

${BOLD}${CMD}${NC} — Download & register a GGUF model from Hugging Face

${BOLD}USAGE${NC}
  ${CMD} <repo_id[:quant]> [model_key] [options]

${BOLD}ARGUMENTS${NC}
  repo_id[:quant]   HuggingFace repo and optional quantization tag (e.g., Q4_K_M)
                    Defaults to Q4_K_M if omitted
  model_key         Key to register in llama-swap config (auto-derived if omitted)

${BOLD}OPTIONS${NC}
  --mmproj-quant    Quantization tag to prefer for mmproj vision projector file (default: f16)
  --embedding       Explicitly mark model as an embedding model
  --pooling <strat> Custom pooling strategy for embedding models (e.g. mean, cls)

${BOLD}EXAMPLES${NC}
  ${CMD} openbmb/MiniCPM-V-4.6-Thinking-gguf:Q4_K_M
  ${CMD} bartowski/Mistral-7B-Instruct-v0.3-GGUF:Q5_K_M mistral
  ${CMD} nomic-ai/nomic-embed-text-v1.5-GGUF:Q4_K_M
  ${CMD} BAAI/bge-large-en-v1.5-gguf:Q4_K_M --pooling cls

EOF
  exit 1
}

HF_REF=""
MODEL_KEY=""
MMPROJ_QUANT=""
EMBEDDING="false"
POOLING=""

# Parse options and arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)
      usage
      ;;
    --mmproj-quant)
      if [[ $# -lt 2 ]]; then
        error "--mmproj-quant requires an argument."
      fi
      MMPROJ_QUANT="$2"
      shift 2
      ;;
    --embedding)
      EMBEDDING="true"
      shift
      ;;
    --pooling)
      if [[ $# -lt 2 ]]; then
        error "--pooling requires an argument."
      fi
      POOLING="$2"
      shift 2
      ;;
    -*)
      error "Unknown option: $1"
      ;;
    *)
      if [[ -z "$HF_REF" ]]; then
        HF_REF="$1"
      elif [[ -z "$MODEL_KEY" ]]; then
        MODEL_KEY="$1"
      else
        error "Unexpected positional argument: $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$HF_REF" ]]; then
  usage
fi

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

# --- Quick host-side embedding pre-detection (before Docker) ----------------
# Skip if user already passed --embedding explicitly
if [[ "$EMBEDDING" != "true" ]]; then
  EMBEDDING=$(python3 -c "
import urllib.request, json, sys
try:
    url = 'https://huggingface.co/api/models/$REPO_ID'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=8) as r:
        info = json.loads(r.read().decode('utf-8'))
    pt = info.get('pipeline_tag', '')
    lb = info.get('library_name', '')
    tags = info.get('tags', [])
    if (pt in ('feature-extraction', 'sentence-similarity') or
        lb == 'sentence-transformers' or
        any(t in tags for t in ('sentence-transformers', 'sentence-similarity', 'feature-extraction'))):
        print('true')
    else:
        print('false')
except:
    print('false')
" 2>/dev/null || echo "false")
  if [[ "$EMBEDDING" == "true" && -z "$POOLING" ]]; then
    POOLING="mean"
  fi
fi

# --- Run the downloader inside python container -----------------------------
header "Downloading from Hugging Face"
step "Repo:  ${BOLD}${REPO_ID}${NC}"
step "Quant: ${BOLD}${QUANT}${NC}"
step "Key:   ${BOLD}${MODEL_KEY}${NC}"
if [[ "$EMBEDDING" == "true" ]]; then
  step "Type:  ${BOLD}Embedding Model${NC}  ${DIM}(pooling: ${POOLING:-mean})${NC}"
fi
if [[ -n "$MMPROJ_QUANT" ]]; then
  step "Projector Quant Preference: ${BOLD}${MMPROJ_QUANT}${NC}"
fi
if [[ -n "$POOLING" && "$EMBEDDING" != "true" ]]; then
  step "Pooling Strategy Override: ${BOLD}${POOLING}${NC}"
fi
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

# Define temp success file to capture filename from inside the container without swallow stdout/stderr
SUCCESS_FILE_HOST="$MODELS_DIR/.success_file_$$"
SUCCESS_FILE_CONTAINER="/models/.success_file_$$"
rm -f "$SUCCESS_FILE_HOST"

TTY_FLAG=""
if [[ -t 1 ]]; then
  TTY_FLAG="-t"
fi

docker run --rm $TTY_FLAG \
  --name "hf-puller-${SAFE_KEY}" \
  -v "$MODELS_DIR:/models" \
  -e HF_HUB_ENABLE_HF_TRANSFER=0 \
  -e HF_HOME=/models/.cache \
  -e REPO_ID="$REPO_ID" \
  -e QUANT="$QUANT" \
  -e MODEL_KEY="$MODEL_KEY" \
  -e MMPROJ_QUANT="$MMPROJ_QUANT" \
  -e EMBEDDING="$EMBEDDING" \
  -e POOLING="$POOLING" \
  -e SUCCESS_FILE_CONTAINER="$SUCCESS_FILE_CONTAINER" \
  "${ENV_ARGS[@]}" \
  -e PYTHONUNBUFFERED=1 \
  python:3.10-slim \
  sh -c "pip install -q huggingface_hub && \
         python3 -u -c \"
import os, sys, json
import urllib.request
import urllib.error
from huggingface_hub import hf_hub_download, list_repo_files

repo = os.environ['REPO_ID']
quant = os.environ['QUANT'].lower()
model_key = os.environ['MODEL_KEY']
mmproj_quant = os.environ.get('MMPROJ_QUANT', '').lower() or None
is_embedding = os.environ.get('EMBEDDING', 'false') == 'true'
pooling = os.environ.get('POOLING', '') or None

# Fetch repository metadata for auto-detection of embedding models
try:
    url = f'https://huggingface.co/api/models/{repo}'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=10) as response:
        info = json.loads(response.read().decode('utf-8'))
        pipeline_tag = info.get('pipeline_tag', '')
        library_name = info.get('library_name', '')
        tags = info.get('tags', [])
        
        is_embedding_detected = (
            pipeline_tag in ('feature-extraction', 'sentence-similarity') or
            library_name == 'sentence-transformers' or
            any(t in tags for t in ('sentence-transformers', 'sentence-similarity', 'feature-extraction'))
        )
        if is_embedding_detected:
            is_embedding = True
except Exception as e:
    print(f'Warning: Could not auto-detect embedding model status: {e}', file=sys.stderr)

if is_embedding and not pooling:
    pooling = 'mean'

try:
    files = list_repo_files(repo)
except Exception as e:
    print(f'ERROR: Failed to list files for repo {repo}: {e}', file=sys.stderr)
    sys.exit(1)

# Main GGUF model resolution (exclude mmproj files from main model matching)
gguf_files = [f for f in files if f.lower().endswith('.gguf') and 'mmproj' not in f.lower()]
matching = [f for f in gguf_files if quant in f.lower()]

if not matching:
    # Fallback to first GGUF file if no exact quant found
    if gguf_files:
        matching = [gguf_files[0]]
    else:
        print(f'ERROR: No GGUF files found in repo {repo}', file=sys.stderr)
        sys.exit(1)

target_file = matching[0]

# mmproj file resolution
mmproj_files = [f for f in files if f.lower().endswith('.gguf') and 'mmproj' in f.lower()]
mmproj_target = None
mmproj_warning = None

if mmproj_files:
    # Try user-requested quant
    if mmproj_quant:
        mmproj_match = [f for f in mmproj_files if mmproj_quant in f.lower()]
        if mmproj_match:
            mmproj_target = mmproj_match[0]
        else:
            mmproj_warning = f'Requested mmproj quant \\'{mmproj_quant}\\' not found.'
    
    # Try default f16
    if not mmproj_target:
        f16_match = [f for f in mmproj_files if 'f16' in f.lower()]
        if f16_match:
            mmproj_target = f16_match[0]
            if mmproj_quant and not mmproj_warning:
                mmproj_warning = f'Requested mmproj quant \\'{mmproj_quant}\\' not found. Falling back to default \\'f16\\'.'
        else:
            # Fallback to the first available mmproj
            mmproj_target = mmproj_files[0]
            if mmproj_quant:
                mmproj_warning = f'Requested mmproj quant \\'{mmproj_quant}\\' and default \\'f16\\' not found. Falling back to \\'{os.path.basename(mmproj_target)}\\'.'
            else:
                mmproj_warning = f'Default mmproj \\'f16\\' not found. Falling back to \\'{os.path.basename(mmproj_target)}\\'.'
else:
    if mmproj_quant:
        mmproj_warning = 'No mmproj files found in repository.'

print(f'Found target file: {target_file}')
if mmproj_target:
    print(f'Found mmproj file: {mmproj_target}')

local_dir = f'/models/{repo}'
target_local_path = os.path.join(local_dir, os.path.basename(target_file))

# Healing / Resume: check if model already downloaded
if os.path.exists(target_local_path):
    print(f'Main model file already exists: {target_local_path}. Skipping download.')
    main_downloaded_name = os.path.basename(target_file)
else:
    print('Starting model download...')
    try:
        path = hf_hub_download(
            repo_id=repo,
            filename=target_file,
            local_dir=local_dir,
            local_dir_use_symlinks=False
        )
        main_downloaded_name = os.path.basename(path)
        print('Model download completed successfully!')
    except Exception as e:
        print(f'ERROR: Download failed: {e}', file=sys.stderr)
        sys.exit(1)

# Download mmproj if found
mmproj_downloaded_name = None
if mmproj_target:
    mmproj_local_path = os.path.join(local_dir, os.path.basename(mmproj_target))
    if os.path.exists(mmproj_local_path):
        print(f'mmproj file already exists: {mmproj_local_path}. Skipping download.')
        mmproj_downloaded_name = os.path.basename(mmproj_target)
    else:
        print('Starting mmproj download...')
        try:
            mmproj_path = hf_hub_download(
                repo_id=repo,
                filename=mmproj_target,
                local_dir=local_dir,
                local_dir_use_symlinks=False
            )
            mmproj_downloaded_name = os.path.basename(mmproj_path)
            print('mmproj download completed successfully!')
        except Exception as e:
            print(f'ERROR: mmproj download failed: {e}', file=sys.stderr)
            sys.exit(1)

# Save results
result = {
    'model': main_downloaded_name,
    'mmproj': mmproj_downloaded_name,
    'warning': mmproj_warning,
    'is_embedding': is_embedding,
    'pooling': pooling
}
with open(os.environ['SUCCESS_FILE_CONTAINER'], 'w') as f:
    json.dump(result, f)
\""

if [[ -f "$SUCCESS_FILE_HOST" ]]; then
  PARSED_JSON=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    print(data.get('model', ''))
    print(data.get('mmproj', '') or '')
    print(data.get('warning', '') or '')
    print('true' if data.get('is_embedding') else 'false')
    print(data.get('pooling', '') or '')
except Exception as e:
    sys.exit(1)
" "$SUCCESS_FILE_HOST")
  
  FILENAME=$(echo "$PARSED_JSON" | sed -n '1p')
  MMPROJ_FILENAME=$(echo "$PARSED_JSON" | sed -n '2p')
  MMPROJ_WARNING=$(echo "$PARSED_JSON" | sed -n '3p')
  IS_EMBEDDING=$(echo "$PARSED_JSON" | sed -n '4p')
  POOLING=$(echo "$PARSED_JSON" | sed -n '5p')
  
  rm -f "$SUCCESS_FILE_HOST"
else
  error "Download failed or target file could not be determined."
fi

if [[ -n "$MMPROJ_WARNING" ]]; then
  warn "$MMPROJ_WARNING"
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
MMPROJ_ARG=""
if [[ -n "$MMPROJ_FILENAME" ]]; then
  MMPROJ_ARG=" --mmproj /models/${REPO_ID}/${MMPROJ_FILENAME}"
fi

EMBEDDING_ARGS=""
CTX_SIZE="2048"
if [[ "$IS_EMBEDDING" == "true" ]]; then
  CTX_SIZE="8192"
  EMBEDDING_ARGS=" --embedding"
  if [[ -n "$POOLING" ]]; then
    EMBEDDING_ARGS="${EMBEDDING_ARGS} --pooling ${POOLING}"
  fi
  info "Detected Embedding Model! Registering with context size ${BOLD}${CTX_SIZE}${NC} and pooling strategy ${BOLD}${POOLING}${NC}."
fi

cat <<EOF >> "$CONFIG_FILE"
  "${MODEL_KEY}":
    cmd: "llama-server --port \${PORT} --model /models/${REPO_ID}/${FILENAME}${MMPROJ_ARG}${EMBEDDING_ARGS} -c ${CTX_SIZE} --threads 4"
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

  # "ready"    = model loaded but idle   → safe to restart
  # "starting" = model actively loading  → wait
  # Anything else (stopping, stopped)    → safe to restart
  if python3 -c "
import sys, json
data = json.loads(sys.argv[1])
busy = [m for m in data.get('running', []) if m.get('state') == 'starting']
sys.exit(1 if busy else 0)
" "$json" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

if check_idle; then
  info "llama-swap is idle. Restarting immediately to apply changes..."
  "$HOMELAB_DIR/lab" restart llama-swap
else
  warn "llama-swap is loading a model — waiting for it to finish before restarting..."
  while ! check_idle; do
    sleep 5
  done
  info "llama-swap is now idle. Restarting..."
  "$HOMELAB_DIR/lab" restart llama-swap
fi

