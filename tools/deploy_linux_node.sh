#!/usr/bin/env bash
# 把 Linux 版客户端构建并安装到局域网测试服务器，作为一个「应用运行节点」。
#   tools/deploy_linux_node.sh            # 同步源码 → 远端构建 release → 安装到 /opt/linkory-app
#   tools/deploy_linux_node.sh start      # 在虚拟显示（Xvfb）上以 systemd 服务运行应用
#   tools/deploy_linux_node.sh stop|status|shot   # 停止 / 状态 / 截图（保存到 /tmp/linkory-node.png）
# 服务器没有登录桌面会话，所以应用跑在 Xvfb 虚拟显示上；首次运行会安装依赖并下载 Flutter SDK。
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/deploy.env
HOST="${DEPLOY_HOST_OVERRIDE:-$DEPLOY_HOST}"
SERVER="http://${HOST#*@}:$DEPLOY_PORT"
ssh_() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }
FLUTTER='$HOME/development/flutter/bin/flutter'
ENVS='export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn;'

case "${1:-build}" in
  build)
    echo "==> 检查依赖"
    ssh_ 'dpkg -s clang cmake ninja-build libgtk-3-dev xvfb libsecret-1-dev libayatana-appindicator3-dev libnotify-dev libgl1-mesa-dri imagemagick >/dev/null 2>&1' \
      || ssh_ 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang cmake ninja-build libgtk-3-dev xvfb libsecret-1-dev libayatana-appindicator3-dev libnotify-dev libgl1-mesa-dri libegl1 libglu1-mesa xz-utils zip rsync imagemagick x11-utils >/dev/null'
    ssh_ "test -x $FLUTTER" || {
      echo "==> 安装 Flutter SDK（约 1 GB，使用 flutter-io.cn 镜像）"
      ssh_ 'mkdir -p ~/development && cd ~/development && curl -fsSL -o flutter.tar.xz https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.7-stable.tar.xz && tar xf flutter.tar.xz && rm flutter.tar.xz'
    }
    echo "==> 同步源码"
    ssh_ "mkdir -p ~/linkory-build"
    rsync -az --delete -e "ssh -o BatchMode=yes" \
      --exclude build/ --exclude .dart_tool/ --exclude '/ios/Pods' --exclude '/macos/Pods' --exclude '/android/.gradle' \
      --exclude ephemeral/ --exclude '.flutter-plugins*' --exclude '.packages' --exclude 'GeneratedPluginRegistrant.*' --exclude '/linux/flutter/generated_plugin*' \
      linkory-app/ "$HOST:linkory-build/linkory-app/"
    echo "==> 远端构建 release（首次较慢）"
    ssh_ "$ENVS cd ~/linkory-build/linkory-app && $FLUTTER config --enable-linux-desktop >/dev/null && $FLUTTER pub get >/dev/null && $FLUTTER build linux --release --dart-define=LINKORY_DEFAULT_SERVER=$SERVER 2>&1 | tail -25; test -x build/linux/x64/release/bundle/linkory_app"
    echo "==> 安装到 /opt/linkory-app"
    ssh_ 'sudo rm -rf /opt/linkory-app.new && sudo cp -r ~/linkory-build/linkory-app/build/linux/x64/release/bundle /opt/linkory-app.new && sudo rm -rf /opt/linkory-app && sudo mv /opt/linkory-app.new /opt/linkory-app && ls /opt/linkory-app | head'
    ;;
  start)
    ssh_ 'sudo bash -s' <<'REMOTE'
cat > /etc/systemd/system/linkory-node.service <<UNIT
[Unit]
Description=Linkory Linux client (virtual display)
After=network-online.target

[Service]
User=ubuntu
Environment=HOME=/home/ubuntu
ExecStart=/usr/bin/xvfb-run -a -s "-screen 0 1280x800x24 -ac" /opt/linkory-app/linkory_app
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl restart linkory-node
sleep 4
systemctl is-active linkory-node
REMOTE
    ;;
  stop) ssh_ 'sudo systemctl stop linkory-node; echo stopped' ;;
  status) ssh_ 'systemctl is-active linkory-node; pgrep -a linkory_app | head -2 | cut -c1-120' || true ;;
  shot)
    ssh_ 'D=$(pgrep -a Xvfb | grep -o ":[0-9]*" | head -1); DISPLAY=$D import -window root /tmp/linkory-node.png && echo saved' 
    scp -q -o BatchMode=yes "$HOST:/tmp/linkory-node.png" /tmp/linkory-node.png && echo "/tmp/linkory-node.png" ;;
  *) echo "用法: $0 [build|start|stop|status|shot]" >&2; exit 2 ;;
esac
