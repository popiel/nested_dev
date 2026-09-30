#!/bin/bash
# tests/fixtures/mock-pvesm-storage-missing.sh — the storage id is unknown.
echo "unknown storage id '${3:-}'" >&2
exit 1
