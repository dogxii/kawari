#!/bin/bash
# 渲染面板对照图到 build/snapshots/sheet.png（浅色 / 深色，未接入 / 多账号）
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SOURCES=()
for f in Sources/Kawari/*.swift; do [[ "$f" == */main.swift ]] || SOURCES+=("$f"); done
swiftc -swift-version 6 -o "$TMP/snapshot" "${SOURCES[@]}" scripts/snapshot/main.swift
mkdir -p build/snapshots
"$TMP/snapshot" build/snapshots/sheet.png
echo build/snapshots/sheet.png
