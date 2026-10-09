#!/usr/bin/env bash
# 跨主机联调：本机（发起方，headless）↔ 局域网测试服务器上真实运行的 Linux 版应用（响应方）。
# 流程：同步源码 → 在服务器 Xvfb 上运行真实应用并自动应答 → 本机驱动：消息往返、双向文件传输（校验 SHA-256）。
#   tools/cross_e2e.sh                 # 通过共享测试服务端（局域网内应走直连）
#   LINKORY_X_EXPECT_LAN=0 tools/cross_e2e.sh   # 不断言走了局域网直连
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f tools/deploy.env ] || { echo "缺少 tools/deploy.env：请复制 tools/deploy.env.example 并填写你的测试服务器" >&2; exit 1; }
. tools/deploy.env
HOST="${DEPLOY_HOST_OVERRIDE:-$DEPLOY_HOST}"
SERVER="http://${HOST#*@}:$DEPLOY_PORT"
export PATH="$HOME/development/flutter/bin:$PATH"
user="cross$RANDOM$RANDOM"; pass="cross-pass-$RANDOM"
ENVS='export PUB_HOSTED_URL=https://pub.flutter-io.cn FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn;'

echo "==> 同步源码到 $HOST"
ssh -o BatchMode=yes "$HOST" "mkdir -p ~/linkory-build"
rsync -az --delete -e "ssh -o BatchMode=yes" \
  --exclude build/ --exclude .dart_tool/ --exclude '/ios/Pods' --exclude '/macos/Pods' --exclude '/android/.gradle' \
  --exclude ephemeral/ --exclude '.flutter-plugins*' --exclude '.packages' --exclude 'GeneratedPluginRegistrant.*' --exclude '/linux/flutter/generated_plugin*' \
  linkory-app/ "$HOST:linkory-build/linkory-app/"

echo "==> 服务器上启动响应方（真实应用 + 虚拟显示），账号 $user"
rlog=/tmp/linkory-responder.log
ssh -o BatchMode=yes "$HOST" "rm -f $rlog; pkill -f '[r]esponder_test' 2>/dev/null; true"
ssh -n -o BatchMode=yes "$HOST" "$ENVS cd ~/linkory-build/linkory-app && ~/development/flutter/bin/flutter pub get >/dev/null 2>&1 && (nohup xvfb-run -a -s '-screen 0 1280x800x24 -ac' ~/development/flutter/bin/flutter test integration_test/responder_test.dart -d linux --dart-define=LINKORY_E2E_URL=$SERVER --dart-define=LINKORY_X_USER=$user --dart-define=LINKORY_X_PASS=$pass > $rlog 2>&1 < /dev/null &)"
trap 'ssh -o BatchMode=yes "$HOST" "pkill -f '[r]esponder_test' 2>/dev/null; true" || true' EXIT

echo "==> 本机发起方（等待对端上线，首次构建 Linux 调试版需要几分钟）"
set +e
(cd linkory-app && LINKORY_E2E_URL="$SERVER" LINKORY_X_USER="$user" LINKORY_X_PASS="$pass" LINKORY_X_EXPECT_LAN="${LINKORY_X_EXPECT_LAN:-1}" \
  flutter test test/e2e_cross_test.dart 2>&1 | grep -v '^\[INFO\] ws\|^\[INFO\] app')
rc=${PIPESTATUS[0]}
set -e
echo "==> 响应方日志（服务器）"
ssh -o BatchMode=yes "$HOST" "grep -E 'RESPONDER|Some tests|All tests|Error|error|\[INFO\] lan|\[WARN\]' $rlog | tail -12" || true
exit $rc
