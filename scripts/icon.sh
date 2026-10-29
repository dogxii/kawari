#!/bin/bash
# 生成 Support/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -swift-version 6 -O -o "$TMP/icon" scripts/icon/Icon.swift scripts/icon/main.swift
mkdir "$TMP/AppIcon.iconset"
"$TMP/icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Support/AppIcon.icns
echo "Support/AppIcon.icns  $(du -k Support/AppIcon.icns | cut -f1) KB"
