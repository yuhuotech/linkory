#!/usr/bin/env bash
# Web <-> native interop: builds the web app, starts a throw-away server (against LINKORY_TEST_DSN), runs the native
# client test and the browser script together.  PREFIX=/web/ serves the page under a path prefix.   MODE=memory tools/e2e_web/run.sh   tests the no-File-System-Access path.
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; . linkory-server/.env.local; set +a
export PATH="$HOME/development/flutter/bin:$PATH"
export E2E_USER=interop$RANDOM$RANDOM
PORT=${PORT:-8095}; DIR=$(mktemp -d); URL=http://127.0.0.1:$PORT
[ -d tools/e2e_web/node_modules ] || (cd tools/e2e_web && npm install --silent)
[ "${SKIP_BUILD:-}" = 1 ] || (cd linkory-app && flutter build web --release --no-web-resources-cdn >/dev/null)
(cd linkory-server && go build -o "$DIR/server" ./cmd/linkory-server)
LINKORY_MYSQL_DSN="$LINKORY_TEST_DSN" LINKORY_ADDR=127.0.0.1:$PORT LINKORY_WEB_DIR="$PWD/linkory-app/build/web" LINKORY_WEB_PREFIX="${PREFIX:-/}" "$DIR/server" >"$DIR/server.log" 2>&1 &
SRV=$!; trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1.5
MODE=${MODE:-fs} PAGE="$URL${PREFIX:-/}" node tools/e2e_web/interop.js "$URL" "$DIR" & WEB=$!
(cd linkory-app && LINKORY_E2E_URL=$URL LINKORY_E2E_DIR=$DIR LINKORY_E2E_USER=$E2E_USER flutter test test/e2e_web_interop_test.dart) && NATIVE=0 || NATIVE=$?
wait $WEB && B=0 || B=$?
echo "native=$NATIVE browser=$B (logs in $DIR)"
exit $((NATIVE + B))
