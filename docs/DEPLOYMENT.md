# 自建部署指南（AT-12）

本文说明如何在一台服务器上独立安装并运行 Linkory 服务端。服务端是单个 Go 程序，依赖一个 MySQL 8 数据库；文件传输只在内存中转，不落盘。

## 1. 前置条件

- Docker 与 Docker Compose v2（或本机 Go 1.26+）
- MySQL 8（utf8mb4）。数据库与账号自行创建：

```sql
CREATE DATABASE linkory CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER 'linkory'@'%' IDENTIFIED BY '<强密码>';
GRANT ALL PRIVILEGES ON linkory.* TO 'linkory'@'%';
```

表结构由服务端启动时自动迁移，无需手工建表。

## 2. 用 Docker Compose 部署

```sh
cd deploy
cp .env.example .env      # 填写 LINKORY_MYSQL_DSN 与 LINKORY_JWT_SECRET
docker compose up -d --build
curl http://127.0.0.1:8080/healthz     # {"status":"ok",...}
```

- DSN 必须带 `parseTime=true&loc=UTC`；数据库在宿主机时用 `host.docker.internal` 访问。
- `LINKORY_JWT_SECRET` 请固定下来（`openssl rand -hex 32`）。未设置时服务端使用随机密钥，重启后所有登录失效；compose 中已将其设为必填。
- 查看日志：`docker compose logs -f server`；升级：`git pull && docker compose up -d --build`；停止：`docker compose down`。

## 3. 不用 Docker

```sh
cd linkory-server
export LINKORY_MYSQL_DSN='...' LINKORY_JWT_SECRET='...' LINKORY_ADDR=':8080'
go run ./cmd/linkory-server        # 或 go build 后运行二进制
```

## 4. 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `LINKORY_MYSQL_DSN` | 无（必填） | MySQL 连接串 |
| `LINKORY_ADDR` | `:8080` | 监听地址 |
| `LINKORY_JWT_SECRET` | 随机 | JWT 签名密钥，至少 32 字节 |
| `LINKORY_ACCESS_TTL` | `15m` | access token 有效期 |
| `LINKORY_REFRESH_TTL` | `720h` | refresh token 有效期 |
| `LINKORY_OFFLINE_MSG_TTL` | `720h` | 未送达离线消息保留期 |
| `LINKORY_MAX_TRANSFER_BYTES` | `2147483648` | 单文件大小上限（2 GiB） |
| `LINKORY_WEB_DIR` | 空 | 网页版静态文件目录；设置后服务端在同一地址托管网页版（见下文） |
| `LINKORY_WEB_PREFIX` | `/` | 网页版挂载的路径前缀，如 `/web/`；留空/`/` 表示占用根目录。构建一次即可，前缀由服务端在返回 `index.html` 时改写 `<base>`，改前缀不需要重新构建 |
| `LINKORY_WEB_ALLOW_CUSTOM_SERVER` | 空 | `true` 时，本服务托管的网页版登录页可以改连其他（HTTPS）服务器 |
| `LINKORY_CORS_ORIGINS` | 空 | 逗号分隔的网页来源（如 `https://my.linkory.cn`），允许它们在浏览器里调用本服务；空 = 只允许同源 |

> 如服务端配置项有变动，以 `linkory-server/internal/config/config.go` 为准。

## 5. 公网访问：HTTPS / WSS 反向代理

生产环境必须使用 HTTPS（WebSocket 走 WSS），不要把 8080 直接暴露到公网。nginx 示例：

```nginx
server {
    listen 443 ssl http2;
    server_name linkory.example.com;
    # ssl_certificate / ssl_certificate_key ...

    client_max_body_size 0;          # 文件流式上传不限制大小
    proxy_request_buffering off;     # 上传不缓冲到磁盘
    proxy_buffering off;             # 下载不缓冲

    location /api/v1/ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 120s;     # 客户端 30s 心跳，需大于 90s
    }
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_read_timeout 3600s;    # 大文件传输
        proxy_send_timeout 3600s;
    }
}
```

客户端「服务器地址」填 `https://linkory.example.com`。

## 6. 运维

- **备份**：只需备份 MySQL 的 `linkory` 库（账号、设备、消息、任务元数据）。
- **清理**：服务端每小时清理超过保留期、未送达的离线消息；过期的传输任务会自动标记 EXPIRED。
- **多实例**：当前在线状态保存在进程内存，仅支持单实例；多实例需要引入 Redis（见开发计划）。
- **安全**：密码使用 Argon2id；refresh token 轮换且库内只存哈希；移除设备后其凭证立即失效。日志不记录密码、令牌与消息内容。

## 7. 验收清单

1. `GET /healthz` 返回 ok。
2. 客户端注册、登录，第二台设备登录同一账号，互相可见（AT-01/02）。
3. 互发消息，一端断网再恢复后补发且不重复（AT-03/04/05）。
4. 发送文件，接收端确认后完成，校验一致（AT-07/08）。
5. 移除设备后，旧凭证访问返回 401（AT-11）。

## 8. 局域网测试端点（开发用）

仓库自带一键脚本，把服务端部署到一台 Ubuntu 机器（`tools/deploy.env` 配置主机与端口，需免密 ssh 和 sudo）：

```sh
make deploy          # 本机交叉编译 linux 二进制 → 上传 → systemd 重启 → 健康检查
make deploy-status   # 服务状态
make deploy-logs     # 最近日志
```

首次执行会自动：创建系统用户 `linkory`、在该机 MySQL 中建库与账号（随机口令）、生成 JWT 密钥并写入 `/etc/linkory/server.env`（root:linkory 640）、安装并启用 `linkory-server.service`。之后重复执行只更新二进制并重启，不会轮换口令或密钥。该机上的客户端通过 `tools/deploy_linux_node.sh` 构建运行，`tools/cross_e2e.sh` 做跨主机联调。


## 网页版

服务端可以同时托管浏览器版客户端：把 Release 里的 `Linkory-<版本>-web.zip` 解压到某个目录，设置 `LINKORY_WEB_DIR` 指向它，重启服务端，浏览器访问服务端地址即可。网页与接口同源，不需要额外配置跨域；网页版就是账号下的又一台设备（类型“浏览器”），与各端客户端互通。

- 使用反向代理时需要 HTTPS，并转发 WebSocket（`Upgrade`/`Connection` 头）。浏览器的设备身份、通知和多标签页互斥都依赖安全上下文（HTTPS 或 localhost）。
- 同一浏览器配置文件 = 一台设备；每个账号最多保留 10 个网页设备，超出时自动清理最久未在线的，30 天未在线的也会被清理。
- 自己构建：`cd linkory-app && flutter build web --release --no-web-resources-cdn`，产物在 `build/web`。
- 设计与限制见 [WEB_DESIGN.md](WEB_DESIGN.md)。

### 用别人托管的网页版连接你的服务器

网页版（例如官方的 `https://my.linkory.cn`）可以连接自建服务器，前提是：你的服务器使用 HTTPS，并设置 `LINKORY_CORS_ORIGINS=https://my.linkory.cn`，然后重启；在网页登录页选「自建服务器」填写你的地址即可。托管网页的一方需开启 `LINKORY_WEB_ALLOW_CUSTOM_SERVER=true`。

### 官网放根目录、网页版放 `/web/`

官方部署（`linkory.yuhuotech.com`）的做法：nginx 把根目录指向官网静态文件（仓库里的 `linkory-web/`），`/api/`、`/healthz`、`/readyz` 和网页版前缀转给服务端：

```nginx
location /api/ { proxy_pass http://127.0.0.1:8090; ... }   # 同时转发 WebSocket，文件中转不限大小、不缓冲
location = /healthz { proxy_pass http://127.0.0.1:8090; }
location /web/ { proxy_pass http://127.0.0.1:8090; }       # 服务端设置 LINKORY_WEB_PREFIX=/web/
location / { root /path/to/linkory-web; try_files $uri $uri/ =404; }
```

客户端里填的服务器地址仍是域名本身，不受影响。前缀可以随意配置（`/web/`、`/app/` 或根目录），只要 nginx 的 location 与 `LINKORY_WEB_PREFIX` 一致。

### 官方主域名与兼容域名

官方主域名为 `https://linkory.yuhuotech.com`，兼容域名 `https://linkory.dev99.cn` 保留，两个域名的官网、`/web/`、API 和 WebSocket 都由同一服务处理，不把旧 API 重定向到新域名。分别使用匹配的 TLS 证书；网页版仍按当前 origin 连接，浏览器本地存储也按 origin 隔离。原生客户端识别两个地址属于同一官方服务，切换后可沿用同一账号的已有设备身份。

生产脚本支持 `PROD_ALIAS_DOMAIN`、`PROD_ALIAS_CERT`、`PROD_ALIAS_KEY`（可选，证书路径未设时复用主域名证书）。主域名和兼容域名生成独立 nginx server 配置，共用路由。只更新官网的 `--site` 不会重建 nginx 域名配置；域名配置变化应执行完整部署。

## 管理后台

管理后台构建及使用说明见 `linkory-admin/README.md`，设计见 `ADMIN_DESIGN.md`。先运行 `npm ci && npm run build`，把 `linkory-admin/dist` 上传至例如 `/data1/www/linkory/admin`，设置 `LINKORY_ADMIN_DIR` 为该目录并重启 Go 服务。默认 Secure Cookie 要求 HTTPS；本机测试可显式设置 `LINKORY_ADMIN_COOKIE_SECURE=false`，不要用于公网。

已有官网 `/` 和用户客户端 `/web/` 时，nginx 增加 `location /admin/ { proxy_pass http://127.0.0.1:8090; }` 和 `location = /admin { return 301 /admin/; }`，代理头与现有 `/api/` 相同（保留 Host、X-Forwarded-Proto）。该规则需同时出现在主域名和兼容域名的配置中；管理会话按域名隔离。

服务端自动执行 `0005_admin.sql`。管理员必须在服务器执行 `linkory-server admin create --username owner --role admin` 后交互输入密码创建，没有默认密码。`readonly` 角色只读；普通用户凭据不能用于后台。生产管理员初始化是单独的运维动作，构建/部署脚本不会自动创建管理员。

持久化数据保留策略默认使用初始 `LINKORY_OFFLINE_MSG_TTL` 天数，管理员修改后以数据库策略为准，离线补发与定期清理均使用该值。已送达消息与终态文件记录初始不自动过期。改策略不会立即删除数据，可先预览；自动清理每小时创建任务。后台 worker 单实例、每批 500 行，任务进度持久化。
