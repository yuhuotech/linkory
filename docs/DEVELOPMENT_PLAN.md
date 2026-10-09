# 连信 Linkory 开发计划

> 依据：`LINKORY_PRD_V1.0.md`、`连信 Linkory 技术架构与开发实施方案 V1.0.md`，以及 monorepo 补充要求。
> 编制日期：2026-10-09

## 1. Monorepo 结构

一级子目录以 `linkory-` 为前缀（相对架构文档中 `apps/ server/ crates/ packages/` 的调整）：

```text
linkory/
├── linkory-server/      # Go 服务端（模块化单体：auth/devices/presence/messages/transfers）
├── linkory-app/         # Flutter 客户端（Windows/macOS/Linux/Android/iOS）
├── linkory-core/        # Rust 核心（阶段 06 引入，现仅占位）
├── linkory-protocol/    # 语言无关的协议定义：OpenAPI、WS 事件 JSON Schema、状态码
├── deploy/              # Docker Compose、环境变量样例
├── docs/                # PRD、架构、开发计划、API 文档
├── Makefile             # 统一入口：make server-test / server-run / up ...
└── README.md
```

原则：各子目录独立构建、独立测试；跨语言的数据结构只以 `linkory-protocol` 为唯一来源。

## 2. 已冻结的关键决策（PRD §12 要求先冻结）

| 项 | 决策 |
|---|---|
| 设备身份 | 登录时客户端生成 Ed25519 密钥对，公钥随注册上传；服务端签发 `device_id`；设备会话 token 与 device 绑定 |
| Token | access（短期，15min）+ refresh（长期，轮换，库内存哈希，可撤销） |
| 密码 | Argon2id |
| 消息语义 | 客户端生成 `client_msg_id`（UUID）保证幂等；状态 `sending → server_received → delivered → failed` |
| 文件任务状态机 | `CREATED → WAITING_ACCEPT → ACCEPTED → TRANSFERRING → VERIFYING → COMPLETED`；终态 `REJECTED/CANCELLED/FAILED/EXPIRED`；服务端校验所有迁移 |
| 文件通道 | WebSocket 只做信令；数据走 HTTPS 流式上传/下载，服务端内存管道中转，不落盘 |
| 离线 | 文字消息保留 30 天（可配置）；文件 V1.0 不离线 |
| 数据库 | MySQL 8（utf8mb4）；迁移用 SQL 文件，启动时自动执行 |
| 在线状态 | 初期 Go 内存（单实例），接口抽象以便后续换 Redis |

## 3. 阶段计划

| 阶段 | 内容 | 主要产出 | 验收 |
|---|---|---|---|
| 01 工程初始化 | monorepo、Go 服务骨架、配置、日志、健康检查、MySQL 迁移框架、Docker Compose、协议目录；Flutter 工程与静态 UI | 可运行骨架 | `make server-test` 通过；`/healthz` 正常；compose 一键起 |
| 02 账号与设备 | 注册/登录/刷新/登出；设备注册、列表、重命名、移除；鉴权中间件 | Auth + Devices API 及测试 | 两客户端同账号互见设备；AT-01/02/10/11 |
| 03 在线与消息 | WS 网关、心跳、状态广播、消息收发/回执/幂等、历史、离线同步 | WS 协议 + messages | AT-03/04/05 |
| 04 剪贴板与文件 | 传输任务状态机、HTTPS 流式中转、SHA-256 校验、取消/失败 | transfers 模块 + 客户端传输中心 | AT-06/07/08/09，1GB 文件 |
| 05 桌面体验 | 托盘、通知、下载目录、日志、打包、基础自动化测试 | 桌面安装包 | 最小化可收消息，重启恢复登录；AT-12 |
| 06 Rust Core + 局域网 | mDNS、加密直连、分块/断点续传、回退中转 | linkory-core | V1.1 验收 |
| 07 移动端 + Linux | Android/iOS 适配、系统分享、Linux 打包 | 五端 | V2.0 前置验收 |

## 4. 环境现状与前置事项

- 已有：Go 1.26、Docker、Rust/cargo、本机 MySQL 与 Redis、Flutter 3.47（已安装于 ~/development/flutter）。
- Xcode 已安装，macOS 应用可构建（包名 com.yuhuo.linkory）；Android SDK 未装。

## 5. 工程规范

- 每阶段先更新 `linkory-protocol`，再实现服务端，再实现客户端。
- Go：`go vet` + `go test ./...`；Flutter：`flutter analyze` + `flutter test`；Rust：`cargo test`。
- 每个阶段结束打 tag 并保持主干可运行。

## 6. 进度（2026-10-09）

- ✅ 阶段 01：monorepo、Go 骨架、迁移框架、Docker Compose（已验证，见 `docs/DEPLOYMENT.md`）。
- ✅ 阶段 02：账号/设备注册/刷新轮换/设备管理/修改密码（集成测试覆盖 AT-01/02/10/11）。
- ✅ 阶段 03：WebSocket 在线状态、消息收发、回执、幂等、离线同步。
- ✅ 阶段 04：传输任务状态机 + 流式中转 + SHA-256 校验；1 GB 文件经 Docker 部署的服务端传输通过（约 15 秒，服务端内存约 140 MB）。
- ✅ 客户端联调：双客户端（独立会话）对真实服务端的端到端测试（`linkory-app/test/e2e_test.dart`）与真机集成测试（`integration_test/app_test.dart`，真实窗口渲染截图）通过。
- ✅ 阶段 05 桌面体验：托盘与关闭到托盘、系统通知、拖拽/多文件发送、隐藏标题栏、开机启动（macOS/Windows/Linux 原生实现）、本地日志、主题设置、凭据存系统钥匙串（不可用时回退）、macOS dmg 打包脚本（`make app-macos-dmg`）。
- ✅ 阶段 06 局域网直连（V1.1）：每任务密钥协商、`LNK1` 加密直连协议、断点续传、失败回退中转、传输方式设置（自动/仅局域网/仅中转）；Rust 参考实现 `linkory-core` 与 Dart 实现双向互操作测试通过。
- 🚧 阶段 07：窄屏单栏布局 + 底部导航已完成（widget 测试），iOS 可构建（`flutter build ios --no-codesign`）；Android 因本机未装 SDK 未构建，Windows/Linux 未在对应系统构建。移动端系统分享入口、移动端通知尚未实现。

### 未完成 / 已知限制

- Android SDK 未安装，Android 未构建；Windows、Linux 桌面未在对应系统构建验证（仅 macOS、iOS 构建过）。
- 局域网直连的加密在 Dart 中为软件实现（AOT 约 40 MB/s）；Rust 参考实现约 240 MB/s，待 FFI 接入后提速（见 `linkory-core/README.md`）。
- 局域网发现采用「服务端交换候选地址」而非 mDNS：同一账号的设备经服务端互知局域网端点，简单可靠，但需要服务端可达；mDNS（无服务端时发现）留待 Rust 核心接入后实现。
- 在线状态为进程内存，仅支持单实例；多实例需 Redis。
- 文件夹传输（FILE-009）、账号恢复（AUTH-008 的恢复部分）、图片剪贴板、自动剪贴板同步未做（均为 P1/后续版本）。
- 直连任务在服务端保持 TRANSFERRING 的上限为 30 分钟。
- 移动端不承诺后台持续在线（系统限制），仅保证前台收发。

## 7. UI 设计规范

整体视觉复刻 cc-switch（Tauri/React/Tailwind）：颜色、圆角（control 6 / panel 10 / dialog 14）、字号（11/12/13/14/15/16/18）、边框与阴影 token 见 `linkory-app/lib/theme/tokens.dart`，主题色橙 `#F97316`，支持深浅色。
布局由 cc-switch 的两栏改为微信式三栏：图标导航栏（72px）｜列表栏（280px）｜内容区；内容区页头 52px，与 cc-switch 的 AppPageHeader 一致。窗口宽度 < 720 时折叠为单栏 + 底部导航（移动端），详见 `docs/UI_SPEC.md`。
