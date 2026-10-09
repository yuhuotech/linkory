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

- 已有：Go 1.26、Docker、Rust/cargo、本机 MySQL（需凭据）。
- **缺少 Flutter SDK**：`linkory-app` 需先安装 Flutter 才能 `flutter create` 并运行；服务端开发不受阻。

## 5. 工程规范

- 每阶段先更新 `linkory-protocol`，再实现服务端，再实现客户端。
- Go：`go vet` + `go test ./...`；Flutter：`flutter analyze` + `flutter test`；Rust：`cargo test`。
- 每个阶段结束打 tag 并保持主干可运行。
