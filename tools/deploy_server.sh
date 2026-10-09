#!/usr/bin/env bash
# 把 linkory-server 部署到局域网测试服务器并重启服务（systemd）。
#   tools/deploy_server.sh            # 构建 → 上传 → 重启 → 健康检查（默认）
#   tools/deploy_server.sh status     # 查看服务状态与版本
#   tools/deploy_server.sh logs [-f]  # 查看日志
# 目标主机见 tools/deploy.env，可用环境变量 DEPLOY_HOST 覆盖。首次部署会自动初始化：
# 系统用户、数据库与账号（口令随机生成）、JWT 密钥、systemd 单元。重复执行是幂等的。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
[ -f tools/deploy.env ] || { echo "缺少 tools/deploy.env：请复制 tools/deploy.env.example 并填写你的测试服务器" >&2; exit 1; }
. tools/deploy.env
HOST="${DEPLOY_HOST_OVERRIDE:-$DEPLOY_HOST}"
SERVICE=linkory-server
ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

cmd="${1:-deploy}"
case "$cmd" in
  status)
    ssh_ "systemctl is-active $SERVICE; systemctl --no-pager -n 0 status $SERVICE | sed -n 1,4p; curl -s http://127.0.0.1:$DEPLOY_PORT/healthz; echo"
    exit 0 ;;
  logs)
    shift || true
    exec ssh -o BatchMode=yes "$HOST" "sudo journalctl -u $SERVICE --no-pager ${*:--n 80}" ;;
  deploy) ;;
  *) echo "用法: $0 [deploy|status|logs [-f]]" >&2; exit 2 ;;
esac

arch=$(ssh_ uname -m)
case "$arch" in x86_64) goarch=amd64 ;; aarch64) goarch=arm64 ;; *) echo "不支持的架构: $arch" >&2; exit 1 ;; esac

echo "==> 构建 linux/$goarch"
out=$(mktemp -d)/linkory-server
(cd linkory-server && GOOS=linux GOARCH=$goarch CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$out" ./cmd/linkory-server)

echo "==> 上传到 $HOST"
scp -q -o BatchMode=yes "$out" "$HOST:/tmp/linkory-server.new"
rm -rf "$(dirname "$out")"

echo "==> 初始化（如需要）并重启服务"
ssh_ "sudo DIR='$DEPLOY_DIR' PORT='$DEPLOY_PORT' DB='$DEPLOY_DB' SERVICE='$SERVICE' bash -s" <<'REMOTE'
set -euo pipefail
id linkory >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin linkory
install -d -m 755 "$DIR" /etc/linkory

# 首次：创建数据库、账号与环境文件（已存在则保持不变，口令不会被轮换）
if [ ! -f /etc/linkory/server.env ]; then
  pw=$(openssl rand -hex 16)
  jwt=$(openssl rand -hex 32)
  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB\` CHARACTER SET utf8mb4;
            CREATE USER IF NOT EXISTS 'linkory'@'localhost' IDENTIFIED BY '$pw';
            ALTER USER 'linkory'@'localhost' IDENTIFIED BY '$pw';
            GRANT ALL PRIVILEGES ON \`$DB\`.* TO 'linkory'@'localhost';"
  umask 077
  cat > /etc/linkory/server.env <<ENV
LINKORY_ADDR=:$PORT
LINKORY_MYSQL_DSN=linkory:$pw@tcp(127.0.0.1:3306)/$DB?parseTime=true&charset=utf8mb4&loc=UTC
LINKORY_JWT_SECRET=$jwt
ENV
  chown root:linkory /etc/linkory/server.env
  chmod 640 /etc/linkory/server.env
  echo "已初始化数据库 $DB 与 /etc/linkory/server.env"
fi

cat > /etc/systemd/system/$SERVICE.service <<UNIT
[Unit]
Description=Linkory server
After=network-online.target mysql.service
Wants=network-online.target

[Service]
User=linkory
Group=linkory
EnvironmentFile=/etc/linkory/server.env
ExecStart=$DIR/linkory-server
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
install -m 755 /tmp/linkory-server.new "$DIR/linkory-server.next"
mv -f "$DIR/linkory-server.next" "$DIR/linkory-server"
rm -f /tmp/linkory-server.new
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"   # SIGTERM → 服务端优雅退出后再启动新进程

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    echo "服务已启动：$(curl -s http://127.0.0.1:$PORT/healthz)"
    exit 0
  fi
  sleep 1
done
echo "服务未能在 30 秒内就绪，最近日志：" >&2
journalctl -u "$SERVICE" --no-pager -n 30 >&2
exit 1
REMOTE

host_ip="${HOST#*@}"
echo "==> 从本机访问 http://$host_ip:$DEPLOY_PORT/healthz"
curl -fsS -m 8 "http://$host_ip:$DEPLOY_PORT/healthz" && echo
echo "完成。客户端服务器地址：http://$host_ip:$DEPLOY_PORT"
