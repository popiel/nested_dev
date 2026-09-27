#!/bin/bash
# tests/fixtures/mock-lspci.sh — stand-in for lspci(8)
#
# Installed as `lspci` on the mock PATH. Driven by two environment variables so
# one script serves every test in the suite:
#
#   LSPCI_FIXTURE  filename under tests/fixtures, used for plain listings and
#                 for bus-scoped queries
#   LSPCI_TABLE    space-separated <bdf>=<vendor:device> pairs answering
#                 `lspci -n -s <bdf>`
#
# Mirrors the argument handling of the real lspci: the three shapes frag/10 and
# frag/30 use are a full listing, a bus-scoped listing, and a per-device query
# with -n.

if [[ "$*" == *"-n -s"* ]]; then
    bdf=$(echo "$*" | awk '{print $NF}')
    for pair in $LSPCI_TABLE; do
        if [ "${pair%%=*}" = "$bdf" ]; then
            echo "$bdf 0300: ${pair#*=}"
            exit 0
        fi
    done
    # A device the table does not know about still has to answer with a
    # vendor:device pair, or the caller sees an empty third field.
    echo "$bdf 0300: ffff:ffff"
    exit 0
fi

if [[ "$*" == *"-s"* && "$*" != *"-n"* ]]; then
    bus=$(echo "$*" | awk '{print $NF}' | cut -d. -f1)
    grep "^${bus}:" "${LSPCI_FIXTURE_PATH}"
    exit 0
fi

cat "$LSPCI_FIXTURE_PATH"
