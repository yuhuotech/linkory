# Linkory 协议 v1（实现源：linkory-server，随阶段更新）

## REST（前缀 `/api/v1`，JSON；错误统一 `{"code","message"}`）
| 接口 | 说明 |
|---|---|
| POST `/auth/register` `{username,password}` | 注册，201 `{user_id}` |
| POST `/auth/login` `{username,password,device:{device_id?,name,type,os_version,app_version,public_key}}` | 登录并自动注册设备；带有效 `device_id` 则复用；返回 `{access_token,refresh_token,expires_in,device_id,user_id}` |
| POST `/auth/refresh` `{refresh_token}` | 轮换 refresh token；旧 token 重放 → 该设备全部会话作废 |
| POST `/auth/logout`（Bearer） | 撤销当前会话 |
| GET `/devices` / PATCH `/devices/{id}` `{name}` / DELETE `/devices/{id}` | 设备列表、重命名、移除（立即使其凭证失效并断开连接） |
| GET `/conversations` | 当前设备的会话列表（对端设备） |
| GET `/messages?peer_device_id=&before=<unix ms>&limit=` | 历史消息，新→旧 |
| GET `/ws`（Bearer，header；浏览器无法设置 header，改用子协议 `Sec-WebSocket-Protocol: linkory.v1, bearer.<access_token>`，服务端选定 `linkory.v1`） | WebSocket |

device.type：`windows|macos|linux|android|ios|web`（`web` 为浏览器，每账号最多 10 个，超出时自动吊销最久未在线的；30 天未在线自动吊销）。登录失败 5 次/5 分钟（用户名+IP）→ 429。
与 PRD 草案的差异：设备注册合并进 `login`（登录即自动注册）。

## WebSocket 帧
```json
{"v":1,"type":"...","event_id":"uuid","request_id":"","ts":1700000000000,"data":{}}
```
心跳：客户端每 30s 发 `ping`，服务端回 `pong`；90s 无任何帧则服务端断开。断线后客户端指数退避重连（上限约 60s）。

| 方向 | type | data |
|---|---|---|
| C→S | `message.send` | `client_msg_id`(UUID，幂等键), `to_device_id`, `type`(text\|clipboard), `content`(≤64KB) |
| S→C | `message.ack` | `client_msg_id, message_id, status(server_received\|delivered), created_at, duplicate` —— 仅表示服务端已收，**不代表送达** |
| S→C | `message.receive` | 完整消息对象（上线时自动补发未送达的离线消息，默认保留 30 天） |
| C→S | `message.delivered` | `message_id`，接收端落库后确认 |
| S→C | `message.delivered` | `message_id, client_msg_id, delivered_at`（发给发送端） |
| S→C | `presence.snapshot` | `online_device_ids[]`（连接建立时） |
| S→C | `device.online` / `device.offline` | `device_id` |
| C→S | `lan.report` | `addrs[]`(本机局域网 IPv4), `port`：声明本机接收直连的监听端点；服务端只保留私网/回环/链路本地地址（≤8 个），断线即失效 |
| S→C | `error` | `code, message` |

消息状态（客户端侧）：sending → server_received → delivered | failed。同一设备仅保留一条最新连接。

## 文件传输（阶段 04）
状态机：`WAITING_ACCEPT → ACCEPTED → TRANSFERRING → VERIFYING → COMPLETED`；终态 `REJECTED/CANCELLED/FAILED/EXPIRED`（所有迁移服务端原子校验）。
超时：WAITING_ACCEPT/ACCEPTED 5 分钟未动作 → EXPIRED；TRANSFERRING/VERIFYING 超 30 分钟 → FAILED。

| 接口 | 角色 | 说明 |
|---|---|---|
| POST `/transfers` `{to_device_id,file_name,size,sha256}` | 发送端 | 创建任务；目标离线 → 409 `receiver_offline`（V1.0 不支持离线文件）；`sha256` 必填（小写 hex） |
| GET `/transfers`、GET `/transfers/{id}` | 双方 | 传输中心 / 状态查询 |
| POST `/transfers/{id}/accept` \| `/reject` | 接收端 | 确认 / 拒绝 |
| POST `/transfers/{id}/cancel` | 双方 | 取消（中断中转） |
| PUT `/transfers/{id}/data` | 发送端 | 原始字节流上传（不要 Base64）；服务端边转发边算 SHA-256，不落盘；不一致 → 任务 FAILED |
| GET `/transfers/{id}/data` | 接收端 | 流式下载，头 `X-Linkory-SHA256`；一端先到最多等待 60s（超时 408，可重试） |
| POST `/transfers/{id}/complete` | 接收端 | 本地 SHA-256 校验通过并保存后调用 → COMPLETED |
| POST `/transfers/{id}/fail` `{reason}` | 接收端 | 本地失败（校验失败/磁盘不足）→ FAILED |

**接收端必须在本地再次计算 SHA-256**，先写临时文件，校验一致后才改名为正式文件并调用 `complete`。
WS 事件（发给双方）：`transfer.offer`（仅接收端）、`transfer.accept|reject|cancel|start|complete|fail|expired|failed`、`transfer.progress {id,bytes,size}`（约 500ms 一次）。
中转路径不支持断点续传：中断后需重新创建任务（直连路径支持，见下）。

## 局域网直连（V1.1，阶段 06）
同一网络内设备可不经服务端中转直接传输；服务端只做协商与状态记录，**文件内容不经过服务端**。

**协商**
- 任务 JSON 增加：`mode`（`relay`\|`lan`，实际承载路径）、`lan_secret`（任务创建时服务端生成的 32 字节随机密钥，hex，只下发给收发双方）、`receiver_lan {addrs[],port}`（接收端最近一次 `lan.report`，仅 WAITING_ACCEPT/ACCEPTED 阶段附带）。
- 接收端 `accept` 后：发送端收到 `transfer.accept`（含 `receiver_lan`）→ 尝试直连；失败则回退 `PUT /data` 中转。接收端 `accept` 后同时发起 `GET /data`，若发送端直连成功则放弃该请求（服务端在发送端未上传时不改变状态）。
- `POST /transfers/{id}/lan/start`（接收端）：直连握手通过后调用，ACCEPTED → TRANSFERRING、`mode=lan`，避免任务被超时清理。
- `POST /transfers/{id}/complete` 带 `{"via":"lan"}`（接收端）：本地校验 SHA-256 与大小通过后，允许从 ACCEPTED/TRANSFERRING 直接 → COMPLETED。中转路径仍须经 VERIFYING。
- 传输方式设置：自动（先直连后中转）/ 仅局域网 / 仅公网中转（客户端本地设置）。

**直连线路协议 `LNK1`（TCP）**
```
S→R  "LNK1" | task_id(16B) | nonceS(16B)
R→S  nonceR(16B) | offset(u64 BE) | HMAC-SHA256(secret, "R"|task_id|nonceS|nonceR|offset)
S→R  HMAC-SHA256(secret, "S"|task_id|nonceS|nonceR|offset)
之后：重复帧 [len u32 BE][ChaCha20-Poly1305(type(1B)|payload)]，type 0=数据(≤256KiB) 1=结束
密钥 = HKDF-SHA256(secret, salt=nonceS|nonceR, info="linkory-lan-v1")，nonce = 4B 零 + u64 帧计数
R→S  1 字节：1=大小与 SHA-256 校验通过，0=失败
```
- 双向互证：只有持有服务端下发 `lan_secret` 的设备才能通过握手（身份验证）；握手前不传任何文件数据。
- `offset` 为接收端已持有的字节数，发送端从该位置继续（断点续传，同一任务内重连最多 3 次，之后回退中转）。接收端用 `.<id>.lan.part` 暂存，校验通过后才改名。
- 直连成功后双方进度由两端本地显示，不经服务端 `transfer.progress`。
- 限制：直连任务保持 TRANSFERRING 的上限仍是 30 分钟（服务端清理阈值）。

## 管理后台 API v1

独立前缀 `/api/admin/v1`，仅同源使用。不接受用户 JWT、跨域例外或匿名注册。管理会话 Cookie `linkory_admin_session`（HttpOnly、SameSite=Strict、生产 Secure、Path=/api/admin/），8 小时到期，服务端仅存 token 哈希。POST 登录要求 `X-Linkory-Admin: 1` 和正确 Origin，其他写请求另需 `X-CSRF-Token`（从会话接口取得）。角色 `admin` / `readonly`，只读禁止所有管理写请求，但可退出和修改本人密码。错误沿用 `{code,message}`，分页响应 `{items,total,page,page_size}`，page_size 最大 100，UTC ISO 时间。

| 方法与地址 | 行为 |
|---|---|
| POST `/auth/login` `{username,password}` | 限流登录；Cookie + `{username,role,csrf_token,expires_at}` |
| GET `/auth/me` | 当前管理会话；返回同上，不返回 cookie |
| POST `/auth/logout` | 撤销本会话并清 Cookie |
| POST `/auth/password` `{old_password,new_password}` | 修改本人密码（至少 12 字符）；撤销其他管理会话 |
| GET `/overview` | 计数、7 日趋势、健康状态、进程中转字节及计数起点 |
| GET `/users?q=&status=&page=&page_size=` | 用户分页；状态 active/disabled |
| GET `/users/{id}` | 用户元数据与关联设备；不返回口令/消息正文 |
| POST `/users/{id}/{disable,enable,revoke}` `{reason}` | 封禁、解封、撤销全部设备会话；封禁/撤销立即断开 WS |
| GET `/devices?q=&user_id=&type=&status=&page=&page_size=` | 设备分页；不含 public_key、协商密钥 |
| GET `/devices/{id}` | 设备元数据 |
| POST `/devices/{id}/{disconnect,remove}` `{reason}` | 强制下线并撤销会话、或移除设备身份；断开 WS |
| GET `/transfers?q=&user_id=&status=&mode=&from=&to=&page=&page_size=` | 任务元数据、文件名/大小/状态/方式/错误/耗时；日期为 UTC 日，to 包含当天 |
| GET `/transfers/{id}` | 任务元数据；不含 lan_secret、SHA、端点或文件字节 |
| POST `/transfers/{id}/cancel` `{reason}` | 守卫状态迁移，非终态任务取消并向双方广播 |
| GET `/retention` | 当前持久化策略：offline_days、delivered_days、transfer_days；后两项 0=不自动清理 |
| PUT `/retention` `{offline_days,delivered_days,transfer_days,reason}` | 校验范围（offline 1–365，其他 0–3650）、保存并审计 |
| POST `/retention/preview` `{kind,user_id?}` | kind=retention/user_messages/user_transfers/user_delete；固定 cutoff，返回一次性 preview_id、影响计数、expires_at；注销存在活动传输时 409 |
| POST `/jobs` `{preview_id,confirm:"删除",reason}` | 同一操作者 10 分钟内一次性消费预览，持久化删除任务；注销排队即冻结账号并撤销凭据 |
| GET `/jobs?page=&page_size=` / GET `/jobs/{id}` | 状态 QUEUED/RUNNING/COMPLETED/FAILED、影响范围、累计删除行数和错误；worker 分批执行并可恢复 |
| POST `/jobs/{id}/retry` `{reason}` | FAILED 任务重试，保持原 cutoff 和范围，不扩展到新数据 |
| GET `/audit?action=&actor=&target=&page=&page_size=` | 审计元数据与操作理由；不含消息正文或敏感凭据 |

策略清理只删除创建早于固定 cutoff 的消息及终态传输任务；不会删正在传输的任务。后台单 worker、持久化任务状态，服务重启将 RUNNING 恢复为 QUEUED 继续。所有写操作校验权限与 CSRF，在数据库事务中保存审计记录后提交。在线状态仍来自现有单实例 Hub。审计和任务日志不随用户注销删除。

管理操作补充：用户封禁/会话撤销、设备下线/移除会取消涉及的活动传输并中止中转流，向原收发双方发送现有完整 `transfer.cancel` 事件。账号有未完成注销任务时不能解封；FAILED 注销任务保持冻结，需处理原因并重试原任务。保留策略修改同时作用于离线补发窗口，不只影响数据库清理。
