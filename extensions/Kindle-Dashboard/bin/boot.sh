#!/bin/sh
set -eu

KOREADER_DIR="${KOREADER_DIR:-/mnt/us/koreader}"
REQUEST="/tmp/kindle-dashboard-open"
LOG="/tmp/kindle-dashboard-launch.log"

if [ ! -x "$KOREADER_DIR/luajit" ] || [ ! -f "$KOREADER_DIR/plugins/kindledashboard.koplugin/main.lua" ]; then
    echo "Install KOReader and the kindledashboard plugin first." >&2
    exit 1
fi

if pidof luajit reader.lua >/dev/null 2>&1; then
    echo "KOReader is running. Open More tools > 阅读仪表盘 inside KOReader." >&2
    exit 1
fi

: > "$REQUEST"
(
    sleep 1
    exec /bin/sh "$KOREADER_DIR/koreader.sh" --kual
) > "$LOG" 2>&1 < /dev/null &