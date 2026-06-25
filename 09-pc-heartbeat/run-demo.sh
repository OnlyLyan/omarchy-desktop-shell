#!/usr/bin/env bash
# Roda o demo standalone do PcHeartbeat.
# Requer: quickshell (AUR quickshell-git) e uma Nerd Font (glifo do coracao).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/files" && pwd)"
export HEARTBEAT_STATS="$DIR/stats.sh"
chmod +x "$DIR/stats.sh" 2>/dev/null || true
exec quickshell -p "$DIR/demo-shell.qml"
