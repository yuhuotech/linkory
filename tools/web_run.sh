#!/usr/bin/env bash
# 在本机运行网页版：构建网页（已构建且代码没变时可跳过）→ 用 .env.local 启动服务端并托管网页 → 打开浏览器。
#   tools/web_run.sh              # 默认 http://127.0.0.1:8098
#   PORT=9000 tools/web_run.sh    # 换端口
#   REBUILD=1 tools/web_run.sh    # 强制重新构建网页
#   NO_OPEN=1 tools/web_run.sh    # 不自动打开浏览器
# 前台运行，Ctrl+C 停止。数据用 linkory-server/.env.local 里的开发库（和 make server-run 同一个库）。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/development/flutter/bin:$PATH"
PORT="${PORT:-8098}"
WEB="$PWD/linkory-app/build/web"

# 版本号取最近的 git tag（去掉 v），tag 之后有新提交时形如 0.1.3-4-g9750ce9，有未提交改动时加 -dirty；版本变了或有未提交改动都会重新构建
VER=$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || echo dev)
if [ "${REBUILD:-}" = 1 ] || [ ! -f "$WEB/index.html" ] || [ "$(cat "$WEB/.version" 2>/dev/null)" != "$VER" ] || [[ "$VER" == *-dirty ]]; then
  echo "==> 构建网页版 ${VER}（首次约 1 分钟）"
  (cd linkory-app && flutter build web --release --no-web-resources-cdn --dart-define=LINKORY_VERSION="$VER")
  echo "$VER" > "$WEB/.version"
fi

[ -f linkory-server/.env.local ] || { echo "缺少 linkory-server/.env.local（数据库连接）" >&2; exit 1; }
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "端口 $PORT 已被占用，请换一个：PORT=9000 $0" >&2
  exit 1
fi

echo "==> 构建服务端"
bin=$(mktemp -d)/linkory-server
(cd linkory-server && go build -o "$bin" ./cmd/linkory-server)

set -a; . linkory-server/.env.local; set +a
export LINKORY_ADDR="127.0.0.1:$PORT" LINKORY_WEB_DIR="$WEB"
trap 'kill $SRV 2>/dev/null || true' EXIT INT TERM
"$bin" &
SRV=$!
for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.3; done
echo "==> 网页版已启动：http://127.0.0.1:$PORT   （Ctrl+C 停止）"
[ "${NO_OPEN:-}" = 1 ] || open "http://127.0.0.1:$PORT" 2>/dev/null || true
wait $SRV
