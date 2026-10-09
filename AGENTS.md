# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, etc.) when working with code in this repository.

连信 Linkory：多设备间互发文字/文件的工具。Monorepo，文档以中文为主。需求与决策见 `docs/`（`DEVELOPMENT_PLAN.md` 含已冻结决策、阶段进度、UI 规范）。

## 目录

- `linkory-server/` Go 模块化单体（auth / devices / messaging / transfers / httpapi）
- `linkory-app/` Flutter 客户端（目标五端；目前只在 widget 测试中验证过 UI）
- `linkory-protocol/PROTOCOL.md` REST + WebSocket 协议的唯一来源；每阶段先改协议，再改服务端，再改客户端
- `linkory-core/` Rust 核心，阶段 06 前仅占位
- `deploy/` Docker Compose（只含 server，使用宿主机 MySQL；未验证）

## 常用命令

```sh
make server-test     # go vet + go test ./...，自动 source linkory-server/.env.local
make server-run      # 用 .env.local 启动服务端
# 单个服务端测试
cd linkory-server && set -a && . ./.env.local && set +a && go test ./internal/httpapi -run TestName -v

cd linkory-app && flutter analyze && flutter test
cd linkory-app && flutter test test/shell_test.dart --plain-name "name"
cd linkory-app && flutter test --update-goldens   # 更新 test/goldens/*.png
```

- Flutter 装在 `~/development/flutter`（PATH 在 `~/.zshrc`，使用 flutter-io.cn 镜像）。Xcode 已装，`flutter build macos --debug` 可通过；应用包名 `com.yuhuo.linkory`。
- 服务端集成测试需要 `LINKORY_TEST_DSN`（指向本机 MySQL 的 `linkory_test` 库），未设置时测试会跳过；DSN 与密码只放在被 git 忽略的 `linkory-server/.env.local`，不要写入受版本控制的文件。
- 本机 8080 被 nginx 占用，开发时服务端用 `LINKORY_ADDR=:8090`，客户端默认地址也是 8090。

## 服务端架构（需跨文件理解的部分）

- 入口 `cmd/linkory-server/main.go` 负责组装：config → DB → 嵌入式 SQL 迁移（`migrations/000N_*.sql`，启动自动执行）→ auth → messaging hub → `httpapi.NewRouter`，并带每小时的过期清理与优雅退出。未配置 `LINKORY_JWT_SECRET` 时使用随机密钥（重启后 token 失效）。
- 所有时间统一 UTC：`database.Open` 强制会话 `time_zone`，DSN 需带 `loc=UTC`。
- 认证：access JWT（HS256，15 分钟）+ 轮换 refresh token（库内只存哈希；复用旧 refresh 会撤销该设备全部会话）。设备在 `/auth/login` 中随公钥（Ed25519）自动注册。登录限流：同用户名+IP 5 分钟内 5 次失败。移除设备通过 `devices.OnRemove` 钩子立即使凭证失效并断开 WS。
- 消息：WS 信封 `{v,type,event_id,request_id,ts,data}`；`client_msg_id` 为幂等键；ack 区分 `server_received` 与 `delivered`；上线时同步离线消息，未送达消息保留 30 天。在线状态目前是进程内存（单实例），接口按可换 Redis 设计。
- 文件传输：状态机 `WAITING_ACCEPT → ACCEPTED → TRANSFERRING → VERIFYING → COMPLETED`，终态 `REJECTED/CANCELLED/FAILED/EXPIRED`，所有迁移用带前置状态条件的 UPDATE 保证合法。数据走 `PUT/GET /transfers/{id}/data`，服务端用 `io.Pipe` 内存中转、边转边算 SHA-256，不落盘；WS 只做信令。接收端必须重新校验 SHA-256，写 `.part` 后再 rename。

## UI 规范（强制，完整版见 [`docs/UI_SPEC.md`](docs/UI_SPEC.md)）

视觉完整复刻 cc-switch（v7 设计系统），唯一差异是布局改为微信式三栏。**写任何 Flutter UI 前先读 `docs/UI_SPEC.md`。**

- 只用 token 与共享控件：颜色 `context.c.xxx`、字号 `Type.xxx`、圆角 `Radii.xxx`、控件 `shared/widgets.dart`。禁止页面里写裸 `Color(0x…)`、裸 `fontSize`、裸圆角；缺控件先加到 `widgets.dart`。
- 三栏：图标栏 72 | 列表栏 280 | 内容区；页头 52；栏间 1px `border` 竖线，不用阴影。
- 主题色橙 `#F97316`；每个视图只有一个 solid 橙色主按钮，其余 neutral/quiet/ghost；无蓝/绿按钮、无渐变。
- 字号：11 徽标 / 12 说明 / **13 正文** / 14 强调 / 15 区块标题 / 16 对话框标题 / 18 页面标题。
- 圆角：控件 6、卡片 10、对话框 14。按钮高 32（compact 28），输入框高 32，徽标高 18，间距用 4 的倍数。
- 图标用 Lucide；交互只有悬停底色 + 按下缩放 0.96，无水波纹，动画 ≤150ms。
- 深色/浅色都必须正确；状态不能只靠颜色。改界面后更新 golden 并检查浅/深色。
- 改 token 时同步修改 `lib/theme/tokens.dart` 与 `docs/UI_SPEC.md`。

## 客户端架构

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
