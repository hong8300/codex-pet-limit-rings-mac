#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tmp
# Keep production declarations intact, replacing only the executable entry point.
sed '/^guard let config = parseConfig() else {/,$d' tools/codex-pet-limit-rings.swift > tmp/limit-state-tests.swift
cat tests/limit-state-tests.swift >> tmp/limit-state-tests.swift
swiftc tmp/limit-state-tests.swift -o tmp/limit-state-tests -framework AppKit -lsqlite3
tmp/limit-state-tests
