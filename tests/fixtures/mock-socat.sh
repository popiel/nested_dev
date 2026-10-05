#!/bin/bash
# tests/fixtures/mock-socat.sh — stand-in for socat(1) with scripted failure.
#
# Installed as `socat` on the mock PATH. Every call is journaled; the first
# $SOCAT_FAIL_REMAINING calls fail (decrementing the counter file), later
# calls stream briefly and succeed. That models QEMU creating its serial
# socket after boot while the capture is already waiting for it.
printf 'socat %s\n' "$*" >> "${MOCK_JOURNAL:?}/socat-journal"
n=0
[ -f "${MOCK_COUNT:?}" ] && n="$(cat "$MOCK_COUNT")"
if [ "$n" -gt 0 ]; then
    printf '%s\n' "$((n - 1))" > "$MOCK_COUNT"
    exit 1
fi
sleep 0.2
exit 0
