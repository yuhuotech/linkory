#!/usr/bin/env bash
# flutter run on this machine's desktop platform; pass a device id to override.
#   tools/app_run.sh                 # macOS -> macos, Linux -> linux, Windows (git bash) -> windows
#   tools/app_run.sh emulator-5554   # any `flutter devices` id
#   LINKORY_SERVER=http://127.0.0.1:8090 tools/app_run.sh   # 改连本机服务端
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$root/tools/deploy.env"
# Default server = the shared LAN test endpoint; override with LINKORY_SERVER=http://127.0.0.1:8090
server="${LINKORY_SERVER:-http://${DEPLOY_HOST#*@}:$DEPLOY_PORT}"
cd "$root/linkory-app"
if [ $# -gt 0 ] && [ -n "$1" ]; then
  dev="$1"; shift
else
  case "$(uname -s)" in
    Darwin) dev=macos ;;
    Linux) dev=linux ;;
    *) dev=windows ;;
  esac
fi
echo "flutter run -d $dev  (默认服务器 $server)"
exec flutter run -d "$dev" --dart-define=LINKORY_DEFAULT_SERVER="$server" "$@"
