#!/bin/bash
# tests/fixtures/mock-pkill.sh — stand-in for pkill(1), journaled, always
# succeeds. Killing is best-effort cleanup in the fragment (stale readers),
# so success here never decides anything.
printf 'pkill %s\n' "$*" >> "${MOCK_JOURNAL:?}/socat-journal"
exit 0
