#!/usr/bin/env bash
# dev-nested-provision.sh — Provision a dev VM clone from the template
# Run inside a freshly cloned dev VM (103+). Sets up workspace, pulls images,
# installs tools. Idempotent. REF: __GITHUB_REF__
set -euo pipefail

LOG="/var/log/dev-nested-provision.log"
mkdir -p "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { printf '%s FATAL: %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; exit 1; }

# --- Source shared personalization (§05) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/personalization.sh" ]; then
    . "${SCRIPT_DIR}/personalization.sh"
else
    die "personalization.sh not found — cannot continue"
fi

log "=== dev-nested-provision starting ==="
export DEBIAN_FRONTEND=noninteractive

# --- 1. Update system ---
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y 2>&1 | tee -a "$LOG"

# --- 2. Install essential tools ---
log "Installing essential tools..."
apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncurses5-dev \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libffi-dev \
    liblzma-dev \
    python3-openssl \
    git \
    curl \
    wget \
    jq \
    unzip \
    tree \
    htop \
    tmux \
    2>&1 | tee -a "$LOG"

# --- 3. Verify Docker ---
if ! docker info >/dev/null 2>&1; then
    log "WARNING: Docker not available — skipping image pulls"
else
    # --- 4. Pull additional images ---
    log "Pulling additional development images..."
    docker pull python:3.12-slim 2>&1 | tee -a "$LOG" || true
    docker pull node:20-slim 2>&1 | tee -a "$LOG" || true
    docker pull eclipse-temurin:21-jre-jammy 2>&1 | tee -a "$LOG" || true
    docker pull opencode/opencode:latest 2>&1 | tee -a "$LOG" || true
    log "Additional images pulled"
fi

# --- 5. Set up workspace ---
log "Setting up workspace..."
mkdir -p /work
chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" /work

# --- 6. Git config ---
log "Setting git config..."
sudo -u "${PERSONALIZATION_USERNAME}" git config --global user.name "${PERSONALIZATION_FULLNAME}"
sudo -u "${PERSONALIZATION_USERNAME}" git config --global user.email "${PERSONALIZATION_EMAIL}"

# --- 7. Verify tools ---
log "Verifying tool availability..."
for cmd in git docker curl wget jq; do
    if command -v "$cmd" >/dev/null 2>&1; then
        log "  ${cmd}: $(command -v "$cmd")"
    else
        log "  WARNING: ${cmd} not found"
    fi
done

# --- Self-disable ---
log "=== dev-nested-provision complete ==="
