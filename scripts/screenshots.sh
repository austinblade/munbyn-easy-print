#!/bin/zsh
# Renders the README screenshots into docs/screenshots from sample data
# (no Bluetooth, print server or printer queue involved).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
OUT=docs/screenshots
rm -rf "$OUT"
"$(swift build --show-bin-path)/MunbynEasyPrint" --render-screenshots "$OUT"
