# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, etc.) when working with code in this repository.

连信 Linkory：多设备间互发文字/文件的工具。Monorepo，文档以中文为主。需求与决策见 `docs/`（`DEVELOPMENT_PLAN.md` 含已冻结决策、阶段进度、UI 规范）。

## 目录

- `linkory-server/` Go 模块化单体（auth / devices / messaging / transfers / httpapi）
- `linkory-app/` Flutter 客户端（目标五端；已构建验证 macOS、iOS）
- `linkory-protocol/PROTOCOL.md` REST + WebSocket 协议的唯一来源；每阶段先改协议，再改服务端，再改客户端
- `linkory-core/` Rust 核心：局域网直连协议 `LNK1` 的参考实现（客户端目前用等价的 Dart 实现，两者有互操作测试）
- `deploy/` Docker Compose（只含 server，使用宿主机/外部 MySQL；部署说明见 `docs/DEPLOYMENT.md`）

## 常用命令

```sh
make server-test     # go vet + go test ./...，自动 source linkory-server/.env.local
make server-run      # 用 .env.local 启动服务端；端口上已有 linkory-server 会先优雅退出再重启，被其他程序占用则报错退出（tools/server_run.sh）
# 单个服务端测试
cd linkory-server && set -a && . ./.env.local && set +a && go test ./internal/httpapi -run TestName -v

make app-run                        # 按当前系统自动选桌面目标启动客户端（DEVICE=xxx 指定其他设备）
cd linkory-app && flutter analyze && flutter test        # = make app-test
cd linkory-app && flutter test test/shell_test.dart --plain-name "name"
cd linkory-app && flutter test --update-goldens   # 更新 test/goldens/*.png

make core-test && make core-build   # Rust；互操作测试 test/lan_test.dart 需要先 core-build
make e2e                            # 双客户端对真实服务端（先 make server-run）；LINKORY_E2E_BIG_MB=1024 加测大文件
# 真实窗口集成测试（会启动 macOS 应用并把截图写到沙盒 tmp，路径见输出 "SHOTS ..."）
cd linkory-app && flutter test integration_test/app_test.dart -d macos --dart-define=LINKORY_E2E_URL=http://127.0.0.1:8090
make app-macos-dmg                  # 打包 .dmg（未签名）

# 局域网测试服务器（配置在 tools/deploy.env，该文件被 git 忽略，样例见 tools/deploy.env.example；需要免密 ssh 与免密 sudo）
make deploy                         # 构建 linux/amd64 服务端并部署重启（首次自动建库建账号、生成 JWT 密钥，systemd 服务 linkory-server）
make deploy-status / deploy-logs
tools/deploy_linux_node.sh build|start|stop|status|shot   # 在该服务器上构建并运行 Linux 版应用（Xvfb 虚拟显示，systemd 服务 linkory-node）
tools/cross_e2e.sh                  # 跨主机联调：本机 ↔ 服务器上的真实 Linux 应用（消息往返 + 双向文件，默认断言走局域网直连）
```

- Flutter 装在 `~/development/flutter`（PATH 在 `~/.zshrc`，使用 flutter-io.cn 镜像）。Xcode 已装，`flutter build macos --debug` 可通过；应用包名 `com.yuhuo.linkory`。
- 服务端集成测试需要 `LINKORY_TEST_DSN`（指向本机 MySQL 的 `linkory_test` 库），未设置时测试会跳过；DSN 与密码只放在被 git 忽略的 `linkory-server/.env.local`，不要写入受版本控制的文件。
- 本机 8080 被 nginx 占用，开发时服务端用 `LINKORY_ADDR=:8090`。`make app-run` 默认让客户端连局域网测试服务端（`LINKORY_SERVER=http://127.0.0.1:8090` 可改连本机）；不带该 define 的构建默认地址是 `http://127.0.0.1:8090`。
- 测试服务器上的敏感配置（数据库口令、JWT 密钥）只在服务器 `/etc/linkory/server.env`，不在仓库里。该机没有登录桌面会话，GUI 只能跑在 Xvfb 上。

## 服务端架构（需跨文件理解的部分）

- 入口 `cmd/linkory-server/main.go` 负责组装：config → DB → 嵌入式 SQL 迁移（`migrations/000N_*.sql`，启动自动执行）→ auth → messaging hub → `httpapi.NewRouter`，并带每小时的过期清理与优雅退出。未配置 `LINKORY_JWT_SECRET` 时使用随机密钥（重启后 token 失效）。
- 所有时间统一 UTC：`database.Open` 强制会话 `time_zone`，DSN 需带 `loc=UTC`。
- 认证：access JWT（HS256，15 分钟）+ 轮换 refresh token（库内只存哈希；复用旧 refresh 会撤销该设备全部会话）。设备在 `/auth/login` 中随公钥（Ed25519）自动注册。登录限流：同用户名+IP 5 分钟内 5 次失败。移除设备通过 `devices.OnRemove` 钩子立即使凭证失效并断开 WS。
- 消息：WS 信封 `{v,type,event_id,request_id,ts,data}`；`client_msg_id` 为幂等键；ack 区分 `server_received` 与 `delivered`；上线时同步离线消息，未送达消息保留 30 天。在线状态目前是进程内存（单实例），接口按可换 Redis 设计。
- 文件传输：状态机 `WAITING_ACCEPT → ACCEPTED → TRANSFERRING → VERIFYING → COMPLETED`，终态 `REJECTED/CANCELLED/FAILED/EXPIRED`，所有迁移用带前置状态条件的 UPDATE 保证合法。数据走 `PUT/GET /transfers/{id}/data`，服务端用 `io.Pipe` 内存中转、边转边算 SHA-256，不落盘；WS 只做信令。接收端必须重新校验 SHA-256，写 `.part` 后再 rename。
- 局域网直连：任务创建时服务端生成 `lan_secret`（仅收发双方可见），接收端经 WS `lan.report` 上报监听端点（服务端只保留私网地址）；发送端在 `transfer.accept` 后先走 `LNK1` 直连（HMAC 互证 + ChaCha20-Poly1305 + 断点续传），失败回退 `PUT /data` 中转。直连完成由接收端 `POST /complete {"via":"lan"}`，握手成功时调 `/lan/start`。协议细节在 `PROTOCOL.md`。

## 发布（GitHub Actions）

推送 tag（`v0.1.0`；带 `-` 的如 `v0.1.0-rc1` 会标为预发布）触发 `.github/workflows/release.yml`：先跑 Go（真实 MySQL）/ Rust / Flutter 测试，通过后并行构建 Windows 安装程序（Inno Setup + 便携 zip）、macOS dmg（未签名）、Linux deb + tar.gz、Android apk（测试签名）、服务端多平台二进制，最后汇总 `SHA256SUMS.txt` 发布到 Release。也可在 Actions 页手动运行（`workflow_dispatch`，只产出构建产物，不发布）。CI 里 `CI=true` 时 golden 像素比较被放行（`test/flutter_test_config.dart`），像素检查只在本机做。iOS 需要 Apple 签名，暂无。

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## 应用内更新

`lib/core/updater.dart`（检查、下载、SHA-256 校验）+ `update_install.dart`（各平台安装）+ `features/update/update_ui.dart`（设置页与对话框）。每小时用 ETag 条件请求查 GitHub Releases（`/releases?per_page=15`，默认含/不含预发布取决于当前版本是否预发布），有新版本时侧栏设置按钮上方出现箭头，点击弹出对话框（立即更新 / 前往下载页 / 忽略此版本）。安装方式：macOS 解压 `…-macos.zip` 后由脱离的 shell 在本进程退出后替换 `.app` 并重开；Windows 静默运行 Inno 安装包（升级同 AppId，`[Run]` 里 `Check: WizardSilent` 负责重启应用）；Linux 用 `apt-get install ./….deb`（先 `sudo -n`，否则 `pkexec`），非 deb 安装则解压 tar.gz；Android 经 FileProvider 交给系统安装器。版本号来自 `--dart-define=LINKORY_VERSION`（CI 传 tag）；Android `versionCode` 用 `github.run_number`，必须递增。**macOS 版不再沙盒**（沙盒进程创建的文件会被强制打隔离标记，更新后的应用打不开；AppDelegate 首次启动会把旧容器里的偏好迁移出来）。**下载源**：默认 GitHub 官方；设置/对话框可切到「国内加速」，依次尝试 `gh-proxy.com`、`ghfast.top`（形如 `<镜像>/<完整 github 地址>`，仅 gh-proxy 转发 API，ghfast 失败自动换下一个），镜像列表可用 `LINKORY_UPDATE_MIRRORS` 覆盖。**安全**：第三方镜像不可信，所以 CI 用私钥（secret `UPDATE_SIGNING_KEY`，本机备份 `~/linkory-update-signing.pem`）给 `SHA256SUMS.txt` 做 Ed25519 签名并发布 `SHA256SUMS.txt.sig`，应用内置公钥（`updatePublicKeyB64`）验签后才比对安装包哈希；安装包文件名还必须以 `Linkory-<版本>-` 开头（防回滚）。换密钥需同时改应用里的公钥。本地演练：`--dart-define=LINKORY_UPDATE_API=<假 feed>` + `LINKORY_UPDATE_AUTOINSTALL=true`。

## UI 规范（强制，完整版见 [`docs/UI_SPEC.md`](docs/UI_SPEC.md)）

视觉完整复刻 cc-switch（v7 设计系统），唯一差异是布局改为微信式三栏。**写任何 Flutter UI 前先读 `docs/UI_SPEC.md`。**

- 只用 token 与共享控件：颜色 `context.c.xxx`、字号 `Type.xxx`、圆角 `Radii.xxx`、控件 `shared/widgets.dart`。禁止页面里写裸 `Color(0x…)`、裸 `fontSize`、裸圆角；缺控件先加到 `widgets.dart`。
- 三栏：图标栏 72 | 列表栏 280 | 内容区；页头 52；栏间 1px `border` 竖线，不用阴影。
- 主题色橙 `#F97316`；每个视图只有一个 solid 橙色主按钮，其余 neutral/quiet/ghost；无蓝/绿按钮、无渐变。
- 字号：11 徽标 / 12 说明 / **13 正文** / 14 强调 / 15 区块标题 / 16 对话框标题 / 18 页面标题。
- 圆角：控件 6、卡片 10、对话框 14。按钮高 32（compact 28），输入框高 32，徽标高 18，间距用 4 的倍数。
- 图标用 Lucide；交互只有悬停底色 + 按下缩放 0.96，无水波纹，动画 ≤150ms。
- 深色/浅色都必须正确；状态不能只靠颜色。改界面后更新 golden 并检查浅/深色。
- 未登录也要能浏览全部界面（不强制登录）：新增依赖账号的入口时，提供未登录说明 + 登录入口（`GuestBanner`/`GuestEmpty`），见 UI_SPEC §11。
- 改 token 时同步修改 `lib/theme/tokens.dart` 与 `docs/UI_SPEC.md`。

## 客户端架构

- `lib/core/lan/lan.dart`：直连协议的 Dart 实现（`lanSend` / `LanListener`）；`store.dart` 负责发送端先直连后回退、接收端放弃中转请求等编排。
- `lib/core/desktop.dart`（窗口/托盘/通知/开机启动）与 `log.dart`、`secrets.dart`（钥匙串存凭据）；测试里 `notifyProvider`、`secretsProvider` 默认是空实现/内存实现。
- `lib/core/`：`api.dart`（401 时自动 refresh）、`session.dart`（登录、设备身份与密钥、存储）、`realtime.dart`（WS、心跳、退避重连）、`store.dart`（`AppStore`：设备、在线状态、消息、传输上传/下载的聚合状态）。状态管理用 Riverpod 3（`Notifier`/`NotifierProvider`，没有 `StateProvider`）。
- `lib/features/*`：按功能分页面；`shell/shell.dart` 是三栏布局（72px 图标栏 | 280px 列表栏 | 内容区，页头 52px）。
- UI 风格移植自 cc-switch，规范见上文及 `docs/UI_SPEC.md`；token 在 `lib/theme/tokens.dart`，通用控件在 `lib/shared/widgets.dart`。
- 测试用 `test/support.dart` 的 `FakeStore` 与夹具；golden 截图里 emoji 显示成方块是测试字体缺失所致。

## 提交规范

提交信息使用 Conventional Commits 格式，**描述部分用中文**：`<type>(<scope>): <描述>`，scope 可省略。

- type：`feat` 新功能 / `fix` 修复 / `docs` 文档 / `style` 仅格式 / `refactor` 重构 / `perf` 性能 / `test` 测试 / `build` 构建与依赖 / `ci` 持续集成 / `chore` 杂项 / `revert` 回滚
- scope 建议取子目录或模块：`server`、`app`、`core`、`protocol`、`deploy`，例如 `feat(server): 添加文件传输状态机`
- 描述简短（约 50 字以内）、动宾结构、不加句号，例如 `feat: 添加README.md文档`、`fix(app): 修复刷新令牌后 WebSocket 未重连`
- 需要说明原因或影响时，空一行后写正文；不兼容变更在 type 后加 `!` 并在正文写 `BREAKING CHANGE:`
- 一次提交只做一件事；不要把无关改动混在一起
- 不要提交 `.env.local` 及任何凭据
