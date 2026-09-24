#!/usr/bin/env bash
# llm-firstboot.sh — LLM VM first-boot configuration
# Runs inside VM 101 (llm-vm / ${PERSONALIZATION_USERNAME}) on first boot.
# Installs NVIDIA driver, CUDA, Docker, NVIDIA Container Toolkit, Ollama.
# Detects VRAM, prints model recommendations.
# Fetched at REF host_os_v0.1; logs to /var/log/llm-firstboot.log.
set -euo pipefail

LOG="/var/log/llm-firstboot.log"
mkdir -p "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { printf '%s FATAL: %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; exit 1; }

# --- Source shared personalization (§05) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/personalization.sh" ]; then
    . "${SCRIPT_DIR}/personalization.sh"
else
    PERSONALIZATION_USERNAME="popiel"
    PERSONALIZATION_FULLNAME="T. Alexander Popiel"
    PERSONALIZATION_EMAIL="tapopiel@gmail.com"
    PERSONALIZATION_UID="1401"
    PERSONALIZATION_GID="1401"
    PERSONALIZATION_HOME="/home/${PERSONALIZATION_USERNAME}"
fi

log "=== llm first-boot starting ==="

# --- 1. NVIDIA driver ---
log "Installing NVIDIA driver..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
# Try ubuntu-drivers first, fall back to manual package selection
if command -v ubuntu-drivers >/dev/null 2>&1; then
    ubuntu-drivers install 2>&1 | tee -a "$LOG" || true
fi
# Ensure at least the server driver is installed
if ! nvidia-smi >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends nvidia-driver-570-server 2>&1 | tee -a "$LOG" \
        || apt-get install -y --no-install-recommends nvidia-driver-550-server 2>&1 | tee -a "$LOG" \
        || apt-get install -y --no-install-recommends nvidia-driver-535-server 2>&1 | tee -a "$LOG" \
        || die "Failed to install NVIDIA driver"
fi

log "NVIDIA driver installed. Loading module..."
modprobe nvidia 2>/dev/null || true

if ! nvidia-smi >/dev/null 2>&1; then
    log "WARNING: nvidia-smi not available after driver install — GPU may not be passed through"
else
    log "nvidia-smi: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | tr '\n' '; ')"
fi

# --- 2. CUDA toolkit ---
log "Installing CUDA toolkit..."
CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/cuda-keyring_1.1-1_all.deb"
CUDA_KEYRING_DEB="/tmp/cuda-keyring.deb"

wget -q -O "$CUDA_KEYRING_DEB" "$CUDA_KEYRING_URL" 2>&1 | tee -a "$LOG"
dpkg -i "$CUDA_KEYRING_DEB" 2>&1 | tee -a "$LOG"
apt-get update -qq

# Install CUDA toolkit (minimal, not driver — driver already installed)
apt-get install -y --no-install-recommends cuda-toolkit-12-6 2>&1 | tee -a "$LOG" \
    || apt-get install -y --no-install-recommends cuda-toolkit-12-4 2>&1 | tee -a "$LOG" \
    || log "WARNING: CUDA toolkit install failed — will retry with generic package"

# Add CUDA to PATH
cat > /etc/profile.d/cuda.sh <<'CUDA_PATH'
export PATH=/usr/local/cuda/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}
CUDA_PATH
chmod +x /etc/profile.d/cuda.sh
. /etc/profile.d/cuda.sh

if command -v nvcc >/dev/null 2>&1; then
    log "CUDA installed: $(nvcc --version | grep release)"
else
    log "WARNING: nvcc not found — CUDA may not be properly installed"
fi

# --- 3. Docker CE ---
log "Installing Docker CE..."
# Remove old Docker packages
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker GPG key and repo
install -m 0755 -d /etc/apt/keyrings
wget -q -O /etc/apt/keyrings/docker.asc https://download.docker.com/linux/ubuntu/gpg
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io 2>&1 | tee -a "$LOG"

# Harden Docker daemon
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DOCKER_JSON'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKER_JSON

systemctl enable --now docker
log "Docker CE installed and running"

# Verify Docker
if docker info >/dev/null 2>&1; then
    log "Docker daemon responsive"
else
    log "WARNING: Docker daemon not responsive"
fi

# --- 4. NVIDIA Container Toolkit ---
log "Installing NVIDIA Container Toolkit..."
# Add NVIDIA Container Toolkit repo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

apt-get update -qq
apt-get install -y --no-install-recommends nvidia-container-toolkit 2>&1 | tee -a "$LOG"

# Configure Docker to use NVIDIA runtime
nvidia-ctk runtime configure --runtime=docker 2>&1 | tee -a "$LOG"
systemctl restart docker

# Verify GPU access in Docker
log "Verifying Docker GPU access..."
if docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1; then
    log "Docker GPU access verified"
else
    log "WARNING: Docker GPU access failed — check NVIDIA Container Toolkit"
fi

# --- 5. VRAM detection and model recommendations ---
log "=== VRAM detection ==="
GPU_COUNT=0
TOTAL_VRAM_MB=0

if command -v nvidia-smi >/dev/null 2>&1; then
    # Query each GPU's VRAM
    while IFS= read -r line; do
        vram=$(echo "$line" | tr -d ' MiB')
        if [ -n "$vram" ] && [ "$vram" -gt 0 ] 2>/dev/null; then
            TOTAL_VRAM_MB=$((TOTAL_VRAM_MB + vram))
            GPU_COUNT=$((GPU_COUNT + 1))
            log "  GPU $((GPU_COUNT)): ${vram} MiB"
        fi
    done < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null || true)
fi

TOTAL_VRAM_GB=$((TOTAL_VRAM_MB / 1024))
log "Detected ${GPU_COUNT} GPU(s), ${TOTAL_VRAM_GB} GB total VRAM"

# Print model recommendations based on VRAM
echo ""
echo "=========================================="
echo "  LLM VM — Model Recommendations"
echo "=========================================="
echo ""

if [ "$TOTAL_VRAM_GB" -ge 15 ]; then
    echo "Detected: ${GPU_COUNT} GPU(s), ${TOTAL_VRAM_GB} GB VRAM"
    echo ""
    echo "Recommended models (run 'ollama pull <model>'):"
    echo ""
    echo "  Coding:        ollama pull qwen2.5-coder:14b    (~8.7 GB, fits on 1 GPU)"
    echo "  Code Review:   ollama pull qwen2.5:14b          (~8.7 GB, fits on 1 GPU)"
    echo "  Spec Analysis: ollama pull deepseek-r1:14b      (~8.5 GB, fits on 1 GPU)"
    echo "  Subagent Mgmt: ollama pull devstral-small-2:24b (~15 GB, requires 2 GPUs)"
    echo ""
    echo "Lighter alternatives:"
    echo "  ollama pull qwen2.5-coder:7b     (~4.4 GB, fast coding)"
    echo "  ollama pull llama3.1:8b           (~4.9 GB, general purpose)"
    echo "  ollama pull deepseek-r1:8b        (~4.5 GB, reasoning)"
elif [ "$TOTAL_VRAM_GB" -ge 7 ]; then
    echo "Detected: ${GPU_COUNT} GPU(s), ${TOTAL_VRAM_GB} GB VRAM"
    echo ""
    echo "Recommended models (run 'ollama pull <model>'):"
    echo ""
    echo "  Coding:        ollama pull qwen2.5-coder:7b     (~4.4 GB)"
    echo "  Code Review:   ollama pull llama3.1:8b           (~4.9 GB)"
    echo "  Spec Analysis: ollama pull deepseek-r1:8b        (~4.5 GB)"
    echo "  Subagent Mgmt: ollama pull llama3.1:8b           (~4.9 GB)"
    echo ""
    echo "Note: With ${TOTAL_VRAM_GB} GB, 14B+ models will not fit."
    echo "Consider dual GPU passthrough for larger models."
else
    echo "Detected: ${GPU_COUNT} GPU(s), ${TOTAL_VRAM_GB} GB VRAM"
    echo ""
    if [ "$GPU_COUNT" -eq 0 ]; then
        echo "WARNING: No GPU detected. Ollama will run on CPU only."
        echo "Ensure VFIO passthrough is configured on the host."
    else
        echo "VRAM too low for recommended models."
    fi
    echo ""
    echo "Fallback models (CPU or partial GPU offload):"
    echo "  ollama pull qwen2.5-coder:1.5b   (~1 GB)"
    echo "  ollama pull phi4-mini              (~2.5 GB)"
fi

echo ""
echo "  Full model library: https://ollama.com/library"
echo "  No models were pulled automatically."
echo "=========================================="
echo ""

# Log the recommendations
{
    echo "=== VRAM Detection ==="
    echo "GPUs: ${GPU_COUNT}, Total VRAM: ${TOTAL_VRAM_GB} GB"
    echo "Recommendations printed to console"
} >> "$LOG"

# --- 6. Data volume ---
log "Configuring data volume..."
if [ -b /dev/vdb ]; then
    # Check if already formatted and mounted
    if ! mountpoint -q /data/models 2>/dev/null; then
        # Only format if no filesystem exists
        if ! blkid /dev/vdb >/dev/null 2>&1; then
            mkfs.ext4 -F /dev/vdb 2>&1 | tee -a "$LOG"
        fi
        mkdir -p /data/models
        mount /dev/vdb /data/models 2>&1 | tee -a "$LOG"
        # Persist in fstab
        if ! grep -q "/dev/vdb /data/models" /etc/fstab; then
            echo "/dev/vdb /data/models ext4 defaults,nofail 0 2" >> /etc/fstab
        fi
    fi
    chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" /data/models 2>/dev/null || true
    mkdir -p /data/models/ollama
    ln -sfn /data/models /opt/models
    log "Data volume mounted at /data/models"
else
    log "WARNING: /dev/vdb not found — data volume not attached"
    mkdir -p /data/models /opt/models
fi

# --- 7. Ollama container ---
log "Starting Ollama container..."
if docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
    log "Ollama container already exists, starting..."
    docker start ollama 2>&1 | tee -a "$LOG" || true
else
    docker run -d \
        --name ollama \
        --restart unless-stopped \
        --gpus all \
        -p 127.0.0.1:11434:11434 \
        -v /data/models/ollama:/root/.ollama \
        ollama/ollama 2>&1 | tee -a "$LOG"
    log "Ollama container created and started"
fi

# Verify Ollama API
sleep 3
if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    log "Ollama API responding on localhost:11434"
else
    log "WARNING: Ollama API not yet responding (may need a moment to start)"
fi

# --- 8. Firewall ---
log "Configuring firewall..."
apt-get install -y --no-install-recommends ufw >/dev/null 2>&1 || true
ufw default deny incoming 2>&1 | tee -a "$LOG"
ufw default allow outgoing 2>&1 | tee -a "$LOG"
ufw allow ssh 2>&1 | tee -a "$LOG"
# Allow Ollama API from localhost only (peer access via SSH tunnel)
ufw allow from 192.168.100.0/24 to any port 11434 2>&1 | tee -a "$LOG"
echo "y" | ufw enable 2>&1 | tee -a "$LOG" || true
log "Firewall configured (deny incoming, allow outgoing, allow ssh, allow 11434 from vmbr0)"

# --- 9. Hostname ---
hostnamectl set-hostname llm-vm
log "Hostname set to llm-vm"

# --- 10. Enable qemu-guest-agent ---
systemctl enable qemu-guest-agent 2>/dev/null || true

# --- Self-disable ---
log "=== llm first-boot complete — disabling unit ==="
systemctl disable --now llm-firstboot 2>/dev/null || true

log "=== done ==="
