#!/usr/bin/env bash
# flutter run on this machine's desktop platform; pass a device id to override.
#   tools/app_run.sh                 # macOS -> macos, Linux -> linux, Windows (git bash) -> windows
#   tools/app_run.sh emulator-5554   # any `flutter devices` id
set -euo pipefail
cd "$(dirname "$0")/../linkory-app"
if [ $# -gt 0 ] && [ -n "$1" ]; then
  dev="$1"; shift
else
  case "$(uname -s)" in
    Darwin) dev=macos ;;
    Linux) dev=linux ;;
    *) dev=windows ;;
  esac
fi
echo "flutter run -d $dev"
exec flutter run -d "$dev" "$@"
