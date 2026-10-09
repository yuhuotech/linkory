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
| GET `/ws`（Bearer，header） | WebSocket |

device.type：`windows|macos|linux|android|ios`。登录失败 5 次/5 分钟（用户名+IP）→ 429。
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
| S→C | `error` | `code, message` |

消息状态（客户端侧）：sending → server_received → delivered | failed。同一设备仅保留一条最新连接。
