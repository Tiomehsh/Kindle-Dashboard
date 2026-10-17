#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 HOST [SSH_PORT [IDENTITY_FILE]]" >&2
    exit 2
fi
host=$1
port=${2:-2222}
identity=${3:-}
project=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
staging=$(mktemp -d "${TMPDIR:-/tmp}/kindle-dashboard.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM

mkdir -p "$staging/payload/koreader/plugins" "$staging/payload/extensions"
cp -R "$project/plugins/kindledashboard.koplugin" "$staging/payload/koreader/plugins/"
cp -R "$project/extensions/Kindle-Dashboard" "$staging/payload/extensions/"
tar -cf "$staging/dashboard.tar" -C "$staging/payload" koreader extensions

set -- -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
if [ -n "$identity" ]; then
    set -- "$@" -i "$identity" -o IdentitiesOnly=yes
fi
if [ -n "${DASHBOARD_SSH_KNOWN_HOSTS:-}" ]; then
    set -- "$@" -o "UserKnownHostsFile=$DASHBOARD_SSH_KNOWN_HOSTS"
fi

ssh "$@" "root@$host" '
    set -eu
    test -x /mnt/us/koreader/luajit
    test -f /mnt/us/koreader/koreader.sh
    tar -xf - -C /mnt/us
    chmod +x /mnt/us/extensions/Kindle-Dashboard/bin/boot.sh
    sync
' < "$staging/dashboard.tar"
echo "Installed. Restart KOReader once, then open More tools > 阅读仪表盘."
