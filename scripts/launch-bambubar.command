#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BINARY="$SCRIPT_DIR/BambuBar"

if [[ ! -x "$BINARY" ]]; then
    osascript -e 'display alert "Nie znaleziono BambuBar" message "Uruchom ponownie skrypt build-app.sh." as critical'
    exit 1
fi

pkill -x BambuBar 2>/dev/null || true
osascript -e 'tell application "Terminal" to set miniaturized of front window to true' >/dev/null 2>&1 || true
exec "$BINARY"
