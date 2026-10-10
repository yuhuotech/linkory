# 连信管理后台

React / TypeScript / Vite 前端，独立于 Flutter 客户端和官网。构建结果为静态文件，所有管理功能调用现有 Go 服务，不需要 Node 生产服务。完整设计与 API 见 `docs/ADMIN_DESIGN.md`、`linkory-protocol/PROTOCOL.md` 管理后台章节。

## 构建与启动

```sh
cd linkory-admin
npm ci
npm run build
```

服务端环境变量：

```sh
LINKORY_ADMIN_DIR=/绝对路径/linkory-admin/dist
LINKORY_ADMIN_COOKIE_SECURE=true
```

服务端托管 `/admin/`、管理 API `/api/admin/v1/`，应同源 HTTPS 部署。后台文件的 Vite base 为 `/admin/`，不要放到用户 Web 客户端 `/web/`。本地 HTTP 联调才使用 `LINKORY_ADMIN_COOKIE_SECURE=false`。

前端自动化测试：`npm test`（vitest + jsdom + Testing Library，覆盖 API 封装的 CSRF/错误映射/会话过期事件、登录、会话失效、封禁需填理由、只读角色隐藏写入口、主题）；`npm run build` 会先跑它。

本地开发可运行 `npm run dev`，默认把 `/api` 代理至本机 8090；可通过环境变量 `LINKORY_ADMIN_API` 指定另一个本机开发服务。请求保留原 Host，供同源 Origin 校验使用。

## 创建与禁用管理员

在配置了 `LINKORY_MYSQL_DSN` 的服务器执行（数据库迁移自动完成）：

```sh
linkory-server admin create --username owner --role admin
linkory-server admin create --username observer --role readonly
linkory-server admin disable --username observer
linkory-server admin passwd --username owner   # 忘记密码时重置，并使该管理员全部会话失效
linkory-server admin list                      # 列出管理员、角色与状态
```

密码通过终端两次输入且不回显，至少 12 字符；不接受命令行密码参数，不内置默认账号或密码。管道输入时读取两行一致的密码，仅用于受控自动化，不应将实际密码保存到仓库。管理员不关联用户设备。禁用或重置密码会立即撤销该管理员的全部会话；这些 CLI 操作同样写入审计。

Docker 部署时将 dist 只读挂载进容器并设置 `LINKORY_ADMIN_DIR`，再通过 `docker compose exec server linkory-server admin create ...` 交互创建账号。nginx 需要将 `/admin/` 和 `/api/admin/` 转发至 Go 服务；现有 `location /api/` 已覆盖管理接口。不会把管理 Cookie 交给官网脚本。

## 已实现功能

- 概览：用户/设备/在线/今日消息/失败任务、7 天 UTC 趋势、数据库健康与进程中转流量。
- 用户：分页搜索、详情、设备关联、封禁/解封、撤销会话、按范围预览清理与注销申请处理。
- 设备：筛选分页、详情、强制下线、移除身份并停止相关活动中转。
- 传输：按日期/账号/状态/方式筛选、详情/错误/耗时、守卫状态取消及关闭实际数据流。
- 数据保留：持久化策略，默认未送达 30 天，其余不自动删除；一次性预览确认、分批后台清理、进度/失败重试与重启恢复。注销排队即冻结账号，活动任务未结束时拒绝注销。
- 审计：登录、权限拒绝、管理操作、删除任务结果，支持分页筛选；不记录口令、令牌、消息正文或文件内容。
- 管理账号：独立会话、两角色、密码修改；修改密码后其他管理会话失效。
- 响应式浅深主题，分页空态、加载/失败反馈、操作理由和不可撤销删除确认。

权限由服务端执行，前端隐藏按钮不是授权依据。仅用户元数据与任务信息可查询，没有用户正文/文件下载入口。当前是单实例后台 worker，沿用现有内存 Hub 架构；多实例部署需先增加分布式 presence、任务租约与生命周期管理。

反向代理：默认仅信任本机 127.0.0.1 / ::1 发来的 X-Forwarded-Proto / X-Real-IP；Docker 等场景将 nginx 的实际连接源地址以 CIDR 写入 `LINKORY_ADMIN_TRUSTED_PROXIES`，并确保 nginx 覆盖这些头。否则管理接口不会把外部伪造代理头用于同源校验或登录限流。
