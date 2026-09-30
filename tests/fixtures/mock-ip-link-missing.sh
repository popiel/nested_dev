#!/bin/bash
# tests/fixtures/mock-ip-link-missing.sh — `ip link show <name>` finds nothing.
# Mirrors the real iproute2 behaviour: a non-zero exit and a message naming the
# device, which is what the preflight has to key off.
if [ "${1:-}" = "link" ]; then
    echo "Device \"${3:-}\" does not exist." >&2
    exit 1
fi
exit 0
