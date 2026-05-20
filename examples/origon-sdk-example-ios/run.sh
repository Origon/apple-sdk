#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found. Install with: brew install xcodegen"
    exit 1
fi

echo "==> Generating Xcode project..."
cd "$SCRIPT_DIR"
xcodegen

echo "==> Opening OrigonSDKExample.xcodeproj..."
open OrigonSDKExample.xcodeproj
