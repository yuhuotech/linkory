#!/usr/bin/env bash
# Start the dev server. If a previous linkory-server is still listening on the port, stop it
# gracefully (SIGTERM, then SIGKILL after a timeout) and start fresh. Anything else holding the
# port is never touched: the script reports it and exits.
set -euo pipefail
cd "$(dirname "$0")/../linkory-server"
set -a
[ -f .env.local ] && . ./.env.local
set +a

addr="${LINKORY_ADDR:-:8080}"
port="${addr##*:}"

pids=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true)
foreign=0
for pid in $pids; do
  name=$(ps -o comm= -p "$pid" 2>/dev/null || true)
  if [ "$(basename "$name")" != "linkory-server" ]; then
    echo "端口 $port 被其他程序占用（不会动它）：" >&2
    ps -o pid=,command= -p "$pid" | cut -c1-160 >&2
    foreign=1
  fi
done
[ "$foreign" = 1 ] && { echo "请先关闭它，或设置 LINKORY_ADDR 换端口。" >&2; exit 1; }

if [ -n "$pids" ]; then
  echo "端口 $port 上已有 linkory-server（pid: $(echo $pids | tr '\n' ' ')），正在优雅退出…"
  kill -TERM $pids 2>/dev/null || true
  for _ in $(seq 1 30); do
    still=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    [ -z "$still" ] && break
    sleep 0.5
  done
  still=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  if [ -n "$still" ]; then
    echo "超时未退出，强制结束：$still" >&2
    kill -KILL $still 2>/dev/null || true
    sleep 0.5
  fi
fi

mkdir -p bin
go build -o bin/linkory-server ./cmd/linkory-server
exec bin/linkory-server
