# 连信 Linkory

在你自己的多台设备之间互发文字和文件。登录同一账号后，设备互相可见，消息实时送达，文件经服务端流式中转（不落盘）并做 SHA-256 校验。

目标平台：Windows / macOS / Linux / Android / iOS（Flutter 单套 UI）。

> 状态：服务端与桌面客户端功能（阶段 01–06）已完成并通过测试，macOS 与 iOS 可构建；Android / Windows / Linux 尚未构建验证。进度与已知限制见 [开发计划](docs/DEVELOPMENT_PLAN.md)。

## 功能

- 账号与设备：注册登录，设备自动注册（Ed25519 公钥），设备重命名与移除，移除后凭证立即失效
- 实时消息：WebSocket 在线状态、文字消息、送达回执、幂等、离线补发（保留 30 天）
- 文件传输：邀请 / 接受 / 拒绝 / 取消 / 重试，多文件与拖拽发送，HTTPS 流式中转，服务端与接收端双重 SHA-256 校验
- 局域网直连：同一网络内端到端加密直传（可断点续传），不可用时自动回退服务端中转；可在设置中选择自动 / 仅局域网 / 仅中转
- 桌面体验：托盘、系统通知、开机启动、关闭到托盘、凭据存系统钥匙串；窄屏自动切换为移动端单栏布局
- 界面：移植自 [cc-switch](https://github.com/farion1231/cc-switch) 的设计系统，微信式三栏布局，浅色 / 深色主题

## 仓库结构

| 目录 | 说明 |
|---|---|
| `linkory-server/` | Go 服务端（模块化单体）+ MySQL |
| `linkory-app/` | Flutter 客户端 |
| `linkory-protocol/` | REST / WebSocket 协议定义（[PROTOCOL.md](linkory-protocol/PROTOCOL.md)） |
| `linkory-core/` | Rust 核心：局域网直连协议 `LNK1` 的参考实现（与客户端的 Dart 实现互操作测试） |
| `deploy/` | Docker Compose |
| `docs/` | PRD、架构方案、开发计划、UI 规范 |

## 快速开始

前置：Go 1.26+、MySQL 8、Flutter 3.x。

### 服务端

```sh
cd linkory-server
cp .env.example .env.local        # 填入 MySQL DSN；.env.local 已被 git 忽略
make -C .. server-run             # 启动，迁移会自动执行
```

主要环境变量：

| 变量 | 说明 |
|---|---|
| `LINKORY_MYSQL_DSN` | MySQL 连接串，需带 `parseTime=true&loc=UTC` |
| `LINKORY_ADDR` | 监听地址，默认 `:8080` |
| `LINKORY_JWT_SECRET` | JWT 密钥；不设置则每次启动随机生成（重启后 token 失效） |
| `LINKORY_TEST_DSN` | 集成测试用库（如 `linkory_test`），未设置则相关测试跳过 |

### 客户端

```sh
cd linkory-app
flutter pub get
flutter run -d macos              # 需要完整 Xcode；其他桌面平台同理
```

登录页的服务器地址填服务端监听地址。

### Docker

```sh
cp deploy/.env.example deploy/.env   # 填写数据库连接与 JWT 密钥
make up      # 构建并启动服务端（连接宿主机 MySQL，见 deploy/docker-compose.yml）
make down
```

## 测试

```sh
make server-test                              # go vet + go test，需要 LINKORY_TEST_DSN
make app-test                                 # flutter analyze + flutter test
make core-test                                # Rust 单元测试
make e2e                                      # 双客户端对真实服务端（先 make server-run）
```

## 文档

- [产品需求 PRD](docs/LINKORY_PRD_V1.0.md)
- [技术架构与实施方案](docs/连信%20Linkory%20技术架构与开发实施方案%20V1.0.md)
- [开发计划与进度](docs/DEVELOPMENT_PLAN.md)
- [UI 规范](docs/UI_SPEC.md)
- [自建部署指南](docs/DEPLOYMENT.md)
- [通信协议](linkory-protocol/PROTOCOL.md)
- AI 编程代理的工作约定：[AGENTS.md](AGENTS.md)

## 路线

阶段 01–06 已完成（工程骨架、账号与设备、在线与消息、文件传输、桌面体验、局域网直连）；阶段 07（Android / iOS / Linux 适配）进行中：窄屏布局已完成，其余待在对应平台构建验证。
