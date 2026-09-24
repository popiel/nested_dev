#!/usr/bin/env bash
# tests/run.sh — run test suite (static + unit)
# Usage: tests/run.sh [--fast]  (--fast = static only, for pre-commit)
set -euo pipefail

FAST="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Dependency check ---
MISSING=""
for cmd in bats shellcheck python3; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING="${MISSING} ${cmd}"
done

if [ -n "$MISSING" ]; then
    echo "ERROR: Missing required tools:${MISSING}" >&2
    echo "" >&2
    echo "Install on Debian/Ubuntu:" >&2
    echo "  sudo apt-get install bats shellcheck python3 python3-yaml" >&2
    echo "" >&2
    echo "Install bats on macOS:" >&2
    echo "  brew install bats-core" >&2
    exit 1
fi

# Optional tools (tests skip gracefully if absent)
OPTIONAL_CMDS="dnsmasq iptables-restore hadolint"
for cmd in $OPTIONAL_CMDS; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  [ok] $cmd found"
    else
        echo "  [--] $cmd not found (some tests will skip)"
    fi
done

echo ""
echo "=== nested_dev test suite ==="
echo "    ROOT: $ROOT_DIR"
echo ""

# --- Static validation ---
echo "--- Static ---"
cd "$ROOT_DIR"

echo "  Lint (shellcheck)..."
bats tests/static/lint.bats

echo "  Config validation..."
bats tests/static/configs.bats

echo "  Invariants..."
bats tests/static/invariants.bats

if [ "$FAST" = "--fast" ]; then
    echo ""
    echo "=== static only (--fast) ==="
    exit 0
fi

# --- Unit tests ---
echo ""
echo "--- Unit ---"

echo "  personalization..."
bats tests/unit/personalization.bats

echo "  resolve-ref..."
bats tests/unit/resolve-ref.bats

echo "  gpu-detect..."
bats tests/unit/gpu-detect.bats

echo "  frag10-iommu..."
bats tests/unit/frag10-iommu.bats

echo "  template..."
bats tests/unit/template.bats

echo "  build-iso..."
bats tests/unit/build-iso.bats

echo ""
echo "=== all passed ==="
