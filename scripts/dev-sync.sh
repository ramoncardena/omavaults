#!/bin/bash

# Copy the working tree into the Omarchy plugins dir (symlinks are rejected
# by the shell) and enable the widget. Saving under ~/.config/omarchy/plugins
# hot-reloads the plugin; run `omarchy restart shell` if IPC (`omarchy-shell
# <id> open`) still reaches the old instance.

set -euo pipefail

ID=io.github.ramoncardena.omavaults
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.config/omarchy/plugins/$ID"

omarchy-plugin-validate "$SRC"
mkdir -p "$DEST"
rm -f "$DEST/OmaVaults.qml"   # pre-0.2 single-file layout
cp -r "$SRC/manifest.json" "$SRC/BarWidget.qml" "$SRC/Panel.qml" "$SRC/Model.js" "$SRC/bin" "$SRC/README.md" "$SRC/LICENSE" "$DEST/"

if ! jq -e --arg id "$ID" '[.bar.layout[][]?.id] | index($id)' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null
  omarchy-plugin-enable "$ID" --after omarchy.tray
fi
echo "Installed $ID -> $DEST"
