#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Config
# ============================================================

LLM_MNT="/mnt/llm"

# Ollama models live on the big XFS volume
OLLAMA_MODELS_DIR="${LLM_MNT}/models"

# Open WebUI data (DB, uploads, etc.)
WEBUI_BASE_DIR="${LLM_MNT}/webui"
WEBUI_DATA_DIR="${WEBUI_BASE_DIR}/data"

# Canonical static dir used by the container
WEBUI_STATIC_DIR="${WEBUI_BASE_DIR}/static"

# Your existing custom static dir (source of truth)
STATIC_SEED_DIR="/home/bates/static"

# Custom built frontend (source of truth)
BUILD_SRC_DIR="/home/bates/src/snes/build"

# Destination for the built frontend (mounted/served)
BUILD_TARGET_DIR="/build"

# Docker image + container name
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
OPENWEBUI_CONTAINER_NAME="open-webui"

# Ollama API endpoint as seen from the container when using --network host
OLLAMA_BASE_URL="http://127.0.0.1:11434"

# How long to wait (seconds) after starting the container
# before overlaying static (to let its own copy finish)
WEBUI_STARTUP_WAIT=10

# ============================================================
# Helpers
# ============================================================

msg() {
  printf '\n[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S')" "$*" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    msg "ERROR: Required command '$1' not found in PATH."
    exit 1
  fi
}

dir_non_empty() {
  [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null || true)" ]
}

# ============================================================
# 0. Basic sanity checks
# ============================================================

msg "Checking required commands..."
require_cmd curl
require_cmd sudo
require_cmd docker
require_cmd rsync

# Make sure /mnt/llm exists and is mounted
if ! mountpoint -q "$LLM_MNT"; then
  msg "ERROR: ${LLM_MNT} is not a mountpoint. Check your /etc/fstab and disk layout."
  exit 1
fi

# ============================================================
# 1. Ensure directory layout for models + webui data/static
# ============================================================

msg "Ensuring directory layout under ${LLM_MNT} (and build mirror)..."

sudo mkdir -p \
  "$OLLAMA_MODELS_DIR" \
  "$WEBUI_DATA_DIR" \
  "$WEBUI_STATIC_DIR" \
  "$BUILD_TARGET_DIR"

# Ollama models dir must be owned by ollama; webui dir by bates
sudo chown -R ollama:ollama "$OLLAMA_MODELS_DIR"
sudo chown -R bates:bates "$WEBUI_BASE_DIR"
sudo chown -R bates:bates "$BUILD_TARGET_DIR"


msg "Directory layout:"
printf '  OLLAMA_MODELS_DIR = %s\n' "$OLLAMA_MODELS_DIR"
printf '  WEBUI_DATA_DIR    = %s\n' "$WEBUI_DATA_DIR"
printf '  WEBUI_STATIC_DIR  = %s\n' "$WEBUI_STATIC_DIR"
printf '  BUILD_TARGET_DIR  = %s\n' "$BUILD_TARGET_DIR"

# ============================================================
# 2. Optional initial seed of static dir (first-time only)
#    This is just to avoid an empty static dir on the very first run.
#    The real override happens AFTER the container starts.
# ============================================================

if dir_non_empty "$STATIC_SEED_DIR"; then
  if ! dir_non_empty "$WEBUI_STATIC_DIR"; then
    msg "Initial seeding: ${WEBUI_STATIC_DIR} from ${STATIC_SEED_DIR} (first-time only)..."
    rsync -a "${STATIC_SEED_DIR}/" "${WEBUI_STATIC_DIR}/"
  else
    msg "${WEBUI_STATIC_DIR} is not empty; skipping initial seeding."
  fi
else
  msg "NOTE: Seed dir ${STATIC_SEED_DIR} does not exist or is empty; skipping initial seeding."
fi

# ============================================================
# 3. Install Ollama (if not present) and configure models dir
# ============================================================

if ! command -v ollama >/dev/null 2>&1; then
  msg "Ollama not found; installing via official installer..."
  # Official Ollama install command for Linux:
  curl -fsSL https://ollama.com/install.sh | sh
else
  msg "Ollama already installed; skipping installation."
fi

# Configure systemd override for ollama.service to use /mnt/llm/models
msg "Configuring Ollama to use ${OLLAMA_MODELS_DIR} for model storage..."

sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<EOF
[Service]
Environment=OLLAMA_MODELS=${OLLAMA_MODELS_DIR}
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama

# Small sanity check (non-fatal if it fails)
if curl -fsS "http://127.0.0.1:11434" >/dev/null 2>&1; then
  msg "Ollama is responding on http://127.0.0.1:11434"
else
  msg "WARNING: Could not reach Ollama at http://127.0.0.1:11434 yet. Check 'sudo systemctl status ollama' if this persists."
fi

# ============================================================
# 4. Deploy Open WebUI container (upgrade-safe)
# ============================================================

msg "Pulling latest Open WebUI image: ${OPENWEBUI_IMAGE} ..."
sudo docker pull "${OPENWEBUI_IMAGE}"

# Stop and remove any existing container with this name
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${OPENWEBUI_CONTAINER_NAME}\$"; then
  msg "Existing container '${OPENWEBUI_CONTAINER_NAME}' found; removing..."
  sudo docker rm -f "${OPENWEBUI_CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

msg "Starting Open WebUI container '${OPENWEBUI_CONTAINER_NAME}' with:"
printf '  Data volume  : %s -> /app/backend/data\n' "$WEBUI_DATA_DIR"
printf '  Static volume: %s -> /app/backend/open_webui/static\n' "$WEBUI_STATIC_DIR"
printf '  Ollama URL   : %s\n' "$OLLAMA_BASE_URL"
printf '  Network mode : host (WebUI at http://localhost:8080)\n'

sudo docker run -d \
  --name "${OPENWEBUI_CONTAINER_NAME}" \
  --restart always \
  --network host \
  -e OLLAMA_BASE_URL="${OLLAMA_BASE_URL}" \
  -v "${WEBUI_DATA_DIR}:/app/backend/data" \
  -v "${WEBUI_STATIC_DIR}:/app/backend/open_webui/static" \
  "${OPENWEBUI_IMAGE}"

msg "Open WebUI container started."

# ============================================================
# 5. Overlay custom static AFTER container startup
#    This wins over the image's own static copy.
# ============================================================

if dir_non_empty "$STATIC_SEED_DIR"; then
  msg "Waiting ${WEBUI_STARTUP_WAIT}s for Open WebUI to initialize static assets..."
  sleep "${WEBUI_STARTUP_WAIT}"

  msg "Overlaying custom static from ${STATIC_SEED_DIR} to ${WEBUI_STATIC_DIR}..."
  rsync -a "${STATIC_SEED_DIR}/" "${WEBUI_STATIC_DIR}/"

  msg "Custom static overlay applied. Hard-refresh the browser to see changes."
else
  msg "NOTE: ${STATIC_SEED_DIR} is empty or missing; skipping post-start static overlay."
fi

# ============================================================
# 6. Mirror built frontend to /build
# ============================================================

if dir_non_empty "$BUILD_SRC_DIR"; then
  msg "Syncing built frontend from ${BUILD_SRC_DIR} to ${BUILD_TARGET_DIR}..."
  sudo rsync -a --delete "${BUILD_SRC_DIR}/" "${BUILD_TARGET_DIR}/"
  msg "Custom build synced to ${BUILD_TARGET_DIR}."
else
  msg "NOTE: Build dir ${BUILD_SRC_DIR} is empty or missing; skipping /build sync."
fi

# ============================================================
# 7. Summary
# ============================================================

msg "============================================================"
msg "Setup complete."

echo
echo "  - Ollama models directory : ${OLLAMA_MODELS_DIR}"
echo "  - Open WebUI data dir     : ${WEBUI_DATA_DIR}"
echo "  - Open WebUI static dir   : ${WEBUI_STATIC_DIR}"
echo "  - Custom build sync       : ${BUILD_SRC_DIR} -> ${BUILD_TARGET_DIR}"
echo "  - Web UI URL (local)      : http://localhost:8080"
echo "  - Web UI URL (llamabox)   : http://llamabox:8080"
echo
echo "Your source-of-truth theme dir is:"
echo "  ${STATIC_SEED_DIR}"
echo "The live-served static dir is:"
echo "  ${WEBUI_STATIC_DIR}"
echo
echo "Edit your theme in ${STATIC_SEED_DIR}, then re-run this script to:"
echo "  - pull updated image (if any),"
echo "  - recreate the container, and"
echo "  - reapply your static overlay."
echo
