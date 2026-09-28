#!/usr/bin/env bash
# tests/wsl-setup.sh — install the test tooling a WSL run needs, without sudo.
#
# Run this once per WSL distro, through tests/run-wsl.sh --setup. Everything
# lands in the invoking user's home directory:
#
#   ~/bin/bats         bats-core, a bash distribution, from a plain clone
#   ~/bin/shellcheck   static binary from the release tarball
#   ~/.bashrc          PATH entry
#
# Why not apt: sudo needs a password in an interactive prompt, and these two
# tools are the only hard requirements beyond python3 and git, which Ubuntu
# already ships. Neither needs root, so this works unattended.
#
# A distro that already provides bats-core and shellcheck system-wide needs
# none of this; tests/run-wsl.sh only requires that the tools it finds are
# native Linux binaries, not Windows ones reached over the /mnt/c mount.
set -euo pipefail

BATS_VER="${BATS_VER:-v1.13.0}"
SC_VER="${SC_VER:-v0.11.0}"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "run this inside WSL, not on $(uname -s)"

log "==> environment"
log "    distro: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
log "    user:   $(id -un)"
log "    home:   $HOME"

mkdir -p "$HOME/bin" "$HOME/src"

# --- bats-core ---
if [ -x "$HOME/bin/bats" ]; then
    log "==> bats-core already installed"
else
    log "==> cloning bats-core $BATS_VER"
    if [ -d "$HOME/src/bats-core/.git" ]; then
        git -C "$HOME/src/bats-core" fetch --depth 1 origin "refs/tags/$BATS_VER:refs/tags/$BATS_VER"
        git -C "$HOME/src/bats-core" checkout -q "$BATS_VER"
    else
        git clone --depth 1 --branch "$BATS_VER" \
            https://github.com/bats-core/bats-core.git "$HOME/src/bats-core"
    fi
    ln -sf "$HOME/src/bats-core/bin/bats" "$HOME/bin/bats"
fi

# --- shellcheck ---
if [ -x "$HOME/bin/shellcheck" ]; then
    log "==> shellcheck already installed"
else
    log "==> downloading shellcheck $SC_VER"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/koalaman/shellcheck/releases/download/${SC_VER}/shellcheck-${SC_VER}.linux.x86_64.tar.xz"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$tmp/sc.tar.xz"
    else
        wget -q "$url" -O "$tmp/sc.tar.xz"
    fi
    tar -xJf "$tmp/sc.tar.xz" -C "$tmp"
    mv "$tmp/shellcheck-${SC_VER}/shellcheck" "$HOME/bin/shellcheck"
    chmod +x "$HOME/bin/shellcheck"
fi

# --- PATH for interactive sessions ---
RC="$HOME/.bashrc"
if ! grep -q 'HOME/bin' "$RC" 2>/dev/null; then
    {
        printf '\n# user-space test tooling (bats-core, shellcheck) for nested_dev\n'
        printf 'export PATH="$HOME/bin:$PATH"\n'
    } >> "$RC"
    log "==> added PATH entry to $RC"
else
    log "==> PATH entry already present in $RC"
fi

# --- Verify ---
export PATH="$HOME/bin:$PATH"
log "==> installed"
log "    bats:       $(bats --version 2>&1)"
log "    shellcheck: $(shellcheck --version 2>/dev/null | sed -n 's/^version: //p')"
log "    python3:    $(command -v python3 || echo MISSING)"
log "    git:        $(command -v git || echo MISSING)"

# A Windows binary found on PATH here would reintroduce the slow path, so
# check what actually resolves.
for tool in bats shellcheck python3 git; do
    resolved="$(command -v "$tool" || true)"
    case "$resolved" in
        /mnt/c/*|/mnt/*)
            die "$tool resolves to a Windows binary ($resolved); this WSL run would be as slow as running it natively on Windows" ;;
    esac
done
log "    all tools resolve to native Linux binaries"
log ""
log "Done. Run the suite with: tests/run-wsl.sh"
