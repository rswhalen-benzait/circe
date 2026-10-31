#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p build
# Compile the presentation layer only; no engine or fabricated production API required.
UI_SOURCES=()
for SOURCE in Sources/CirceUI/*.swift; do
    case "$SOURCE" in */EngineBridge.swift) continue ;; esac
    UI_SOURCES+=("$SOURCE")
done
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    "${UI_SOURCES[@]}" scripts/preview-ui.swift -o build/circe-ui-preview
build/circe-ui-preview "$PROJECT_ROOT/build/previews"
