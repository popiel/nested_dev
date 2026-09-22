# LLM VM Specification

## Overview

Ubuntu 26.04 LTS VM dedicated to running large language models via
NVIDIA GPU passthrough (2x GTX 1080, 16 GB combined VRAM). Docker-based
workloads run inside this VM for isolation and reproducibility.

## VM Configuration

| Parameter | Value |
|-----------|-------|
| VM ID | 100 |
| Name | llm |
| OS | Ubuntu 26.04 LTS (Resolute Raccoon) |
| CPU | 6 cores, host passthrough |
| RAM | 10 GB max (balloon driver enabled) |
| GPU | 2x GTX 1080 via VFIO (16 GB VRAM total) |
| Disk | 80 GB (local-lvm, virtio-scsi) |
| Network | virtio NIC on vmbr0 |
| Boot | UEFI (OVMF), q35 machine type |
| Display | none (headless — serial console only) |
| Agent | QEMU guest agent enabled |

## GPU Setup Inside VM

### Install NVIDIA Driver

```bash
# Add NVIDIA repository (Ubuntu 26.04)
apt-get update
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall

# Or install specific version
# apt-get install -y nvidia-driver-590-server

# Verify
nvidia-smi
# Should show both GTX 1080s
```

### CUDA Toolkit

```bash
# Install CUDA toolkit (version compatible with driver)
apt-get install -y nvidia-cuda-toolkit

# Verify
nvcc --version
```

### Multi-GPU Configuration

Both GTX 1080s are passed through as separate PCI devices. The NVIDIA
driver should detect both GPUs automatically:

```bash
nvidia-smi -L
# GPU 0: GeForce GTX 1080 (UUID: GPU-xxxx)
# GPU 1: GeForce GTX 1080 (UUID: GPU-yyyy)
```

For inference workloads, use CUDA device assignment:
- `CUDA_VISIBLE_DEVICES=0` for first GPU
- `CUDA_VISIBLE_DEVICES=1` for second GPU
- `CUDA_VISIBLE_DEVICES=0,1` for both GPUs (tensor parallelism)

## Docker Workloads

### Install Docker

```bash
# Install Docker CE
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# Install NVIDIA Container Toolkit (for GPU access in containers)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit

# Configure Docker runtime
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Verify GPU access in containers
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

### Container Images for LLM Inference

```bash
# Ollama (easy local LLM serving)
docker run -d \
  --gpus all \
  -v /opt/ollama:/root/.ollama \
  -p 11434:11434 \
  --name ollama \
  --restart unless-stopped \
  ollama/ollama

# Pull and run a model
docker exec ollama ollama pull llama3:8b
docker exec ollama ollama run llama3:8b

# vLLM (high-performance serving)
docker run -d \
  --gpus all \
  -v /opt/models:/models \
  -p 8000:8000 \
  --name vllm \
  --restart unless-stopped \
  vllm/vllm-openai:latest \
  --model /models/llama-3-8b \
  --tensor-parallel-size 2

# llama.cpp server
docker run -d \
  --gpus all \
  -v /opt/models:/models \
  -p 8080:8080 \
  --name llama-cpp \
  --restart unless-stopped \
  ghcr.io/ggerganov/llama.cpp:server \
  -m /models/llama-3-8b.Q4_K_M.gguf \
  --n-gpu-layers 99 \
  --host 0.0.0.0 \
  --port 8080
```

### Model Storage

Models are stored on the VM disk at `/opt/models/`:

```
/opt/models/
├── ollama/           # Ollama model storage
├── vllm/             # vLLM model cache
├── huggingface/      # HuggingFace cache
└── downloads/        # Manual model downloads
```

80 GB disk allows storing several 7-8B parameter models in quantized
form (~4 GB each in Q4_K_M quantization).

## Network Configuration

| Port | Service | Access |
|------|---------|--------|
| 22 | SSH | Management only |
| 11434 | Ollama API | localhost (bind to Docker network) |
| 8000 | vLLM API | localhost (bind to Docker network) |
| 8080 | llama.cpp | localhost (bind to Docker network) |

### Firewall

```bash
# Only allow SSH inbound
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw enable
```

API services should only be accessible via SSH tunnel or from the
Desktop VM. Do not expose LLM APIs directly to the network.

## Disk Layout

```
/ (ext4, 80 GB)
├── /opt/
│   ├── models/       # LLM model files (~40-60 GB)
│   ├── ollama/       # Ollama data
│   └── docker/       # Docker data root
├── /var/lib/docker/  # Docker images, containers
└── /home/ubuntu/     # User workspace
```

Consider mounting `/opt/models` as a separate logical volume for
easier backup and rebuild.

## Resource Limits

When both VMs run simultaneously on 16 GB total RAM:

| Metric | Value |
|--------|-------|
| RAM guaranteed | 2 GB (minimum for boot) |
| RAM maximum | 10 GB (balloon driver) |
| CPU cores | 6 (shared with host scheduler) |
| GPU VRAM | 16 GB (2x 8 GB, pinned) |

### Tuning for Low-Memory Operation

```bash
# Reduce Docker memory usage
cat > /etc/docker/daemon.json << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

# Configure swappiness (prefer keeping working set in RAM)
echo 'vm.swappiness=10' >> /etc/sysctl.conf
sysctl -p
```

## Rebuild Procedure

1. Shut down the VM
2. Delete VM from Proxmox
3. Import fresh FAI-generated disk image (see `image-generation.md`)
4. Apply cloud-init configuration
5. Start VM — NVIDIA drivers, Docker, and model storage are pre-installed

## Security Considerations

- No outbound network access except for model downloads (use firewall)
- Docker containers run with `--gpus` flag for secure GPU sharing
- SSH key-only authentication
- LLM APIs not exposed to external network
- VM is rebuilt regularly to contain any corruption
