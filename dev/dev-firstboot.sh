#!/usr/bin/env bash
# dev-firstboot.sh — Dev VM first-boot configuration
# Runs inside VM 102+ (dev-vm / ${PERSONALIZATION_USERNAME}) on first boot.
# Installs Docker, pulls base images, installs Dockerfiles + wrapper scripts.
# Tool images are built lazily by wrapper scripts on first use.
# Fetched at REF host_os_v0.1; logs to /var/log/dev-firstboot.log.
set -euo pipefail

LOG="/var/log/dev-firstboot.log"
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
    PERSONALIZATION_HOME="/home/${PERSONALIZATION_USERNAME}"
fi

log "=== dev first-boot starting ==="
export DEBIAN_FRONTEND=noninteractive

# --- 1. Docker CE ---
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

# Add user to docker group
usermod -aG docker "${PERSONALIZATION_USERNAME}"

# Harden Docker daemon
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DOCKER_JSON'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
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

# --- 2. Workspace ---
log "Setting up workspace..."
mkdir -p /work
chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" /work
log "Workspace ready at /work"

# --- 3. Git config ---
log "Setting git config..."
sudo -u "${PERSONALIZATION_USERNAME}" git config --global user.name "${PERSONALIZATION_FULLNAME}"
sudo -u "${PERSONALIZATION_USERNAME}" git config --global user.email "${PERSONALIZATION_EMAIL}"
log "Git config: user.name='${PERSONALIZATION_FULLNAME}', user.email='${PERSONALIZATION_EMAIL}'"

# --- 4. Base image pulls ---
log "Pulling base images (parallel)..."
docker pull eclipse-temurin:21-jre-jammy 2>&1 | tee -a "$LOG" &
PID_JAVA=$!
docker pull coursier/jre:21 2>&1 | tee -a "$LOG" &
PID_SCALA=$!
docker pull sbtscala/sbt:1.10.7_2.13.15_3 2>&1 | tee -a "$LOG" &
PID_SBT=$!
docker pull node:20-slim 2>&1 | tee -a "$LOG" &
PID_NODE=$!

# Wait for all pulls
FAIL=0
wait $PID_JAVA || FAIL=1
wait $PID_SCALA || FAIL=1
wait $PID_SBT || FAIL=1
wait $PID_NODE || FAIL=1

if [ "$FAIL" -eq 1 ]; then
    log "WARNING: One or more base image pulls failed"
else
    log "All base images pulled successfully"
fi

# Log image SHAs
for img in eclipse-temurin:21-jre-jammy coursier/jre:21 sbtscala/sbt:1.10.7_2.13.15_3 node:20-slim; do
    sha=$(docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "unknown")
    log "  ${img}: ${sha}"
done

# --- 5. Install Dockerfiles ---
log "Installing Dockerfiles..."
DOCKER_DIR="/opt/dev-docker"
mkdir -p "$DOCKER_DIR"
# Dockerfiles are embedded on the ISO at /dev/docker/
if [ -d "${SCRIPT_DIR}/docker" ]; then
    cp -r "${SCRIPT_DIR}/docker/"* "$DOCKER_DIR/"
elif [ -d /dev/docker ]; then
    cp -r /dev/docker/* "$DOCKER_DIR/"
else
    die "Dockerfiles not found on ISO"
fi
chown -R root:root "$DOCKER_DIR"
chmod -R 755 "$DOCKER_DIR"
log "Dockerfiles installed to ${DOCKER_DIR}"

# --- 6. Wrapper scripts (lazy-build pattern) ---
log "Creating wrapper scripts..."
BIN_DIR="${PERSONALIZATION_HOME}/.local/bin"
mkdir -p "$BIN_DIR"

cat > "${BIN_DIR}/java" <<'WRAPPER_JAVA'
#!/usr/bin/env bash
# Ephemeral Java wrapper — builds dev-java image on first use
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-java"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.java" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.cache/coursier:/home/${USER}/.cache/coursier" \
  "$IMAGE" java "$@"
WRAPPER_JAVA

cat > "${BIN_DIR}/scala" <<'WRAPPER_SCALA'
#!/usr/bin/env bash
# Ephemeral Scala wrapper — builds dev-scala image on first use
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-scala"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.scala" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.cache/coursier:/home/${USER}/.cache/coursier" \
  "$IMAGE" scala "$@"
WRAPPER_SCALA

cat > "${BIN_DIR}/sbt" <<'WRAPPER_SBT'
#!/usr/bin/env bash
# Ephemeral sbt wrapper — builds dev-sbt image on first use
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-sbt"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.sbt" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.sbt:/home/${USER}/.sbt" \
  -v "${HOME}/.ivy2:/home/${USER}/.ivy2" \
  -v "${HOME}/.cache/coursier:/home/${USER}/.cache/coursier" \
  "$IMAGE" sbt "$@"
WRAPPER_SBT

cat > "${BIN_DIR}/opencode" <<'WRAPPER_OPENCODE'
#!/usr/bin/env bash
# Ephemeral opencode wrapper — builds dev-opencode image on first use
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-opencode"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.opencode" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.config/opencode:/home/${USER}/.config/opencode:ro" \
  "$IMAGE" opencode "$@"
WRAPPER_OPENCODE

chmod +x "${BIN_DIR}/java" "${BIN_DIR}/scala" "${BIN_DIR}/sbt" "${BIN_DIR}/opencode"
chown -R "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "$BIN_DIR"
log "Wrapper scripts created in ${BIN_DIR}"

# Add ~/.local/bin to PATH via .bashrc
BASHRC="${PERSONALIZATION_HOME}/.bashrc"
if ! grep -q '.local/bin' "$BASHRC" 2>/dev/null; then
    echo '' >> "$BASHRC"
    echo '# Dev tool wrappers (§05)' >> "$BASHRC"
    echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "$BASHRC"
    chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "$BASHRC"
    log "Added ~/.local/bin to PATH in .bashrc"
fi

# --- 7. Cache directories ---
log "Setting up cache directories..."
CACHE_DIRS=(
    "${PERSONALIZATION_HOME}/.sbt"
    "${PERSONALIZATION_HOME}/.ivy2"
    "${PERSONALIZATION_HOME}/.cache/coursier"
    "${PERSONALIZATION_HOME}/.config/opencode"
)
for dir in "${CACHE_DIRS[@]}"; do
    mkdir -p "$dir"
done
chown -R "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" \
    "${PERSONALIZATION_HOME}/.sbt" \
    "${PERSONALIZATION_HOME}/.ivy2" \
    "${PERSONALIZATION_HOME}/.cache" \
    "${PERSONALIZATION_HOME}/.config"
log "Cache directories ready"

# --- 8. Firewall ---
log "Configuring firewall..."
apt-get install -y --no-install-recommends ufw >/dev/null 2>&1 || true
ufw default deny incoming 2>&1 | tee -a "$LOG"
ufw default deny outgoing 2>&1 | tee -a "$LOG"
ufw allow ssh 2>&1 | tee -a "$LOG"
# Allow outbound DNS, HTTP, HTTPS (for image pulls and package repos)
ufw allow out 53 2>&1 | tee -a "$LOG"
ufw allow out 80 2>&1 | tee -a "$LOG"
ufw allow out 443 2>&1 | tee -a "$LOG"
echo "y" | ufw enable 2>&1 | tee -a "$LOG" || true
log "Firewall configured (deny in/out, allow ssh, allow out 53/80/443)"

# --- 9. Hostname ---
hostnamectl set-hostname dev-vm
log "Hostname set to dev-vm"

# --- 10. Enable qemu-guest-agent ---
systemctl enable qemu-guest-agent 2>/dev/null || true

# --- Self-disable ---
log "=== dev first-boot complete — disabling unit ==="
systemctl disable --now dev-firstboot 2>/dev/null || true

log "=== done ==="
