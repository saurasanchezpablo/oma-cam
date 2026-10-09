#!/bin/bash
# Copy the working tree into the Omarchy plugin dir and restart the shell.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/.config/omarchy/plugins/io.github.saurasanchezpablo.droidcam"
mkdir -p "$DEST/bin"
cp manifest.json Service.qml Panel.qml Model.js LICENSE "$DEST/"
cp bin/droidcam-helper.sh "$DEST/bin/"
if [[ -f README.md ]]; then cp README.md "$DEST/"; fi
if [[ -f preview.png ]]; then cp preview.png "$DEST/"; fi
# Hot reload keeps compiled QML and kept services around, so restart.
omarchy restart shell >/dev/null 2>&1
