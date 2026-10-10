# 连信 Linkory 安全测试报告（2026-10）

测试范围：服务端（`linkory-server`，Go）、管理后台（`linkory-admin`，React）、客户端（`linkory-app`，Flutter，含局域网直连协议）、CI/部署脚本（`tools/deploy_prod.sh`、`.github/workflows/release.yml`、`deploy/`）。

测试方法：
1. 代码层系统审查：认证与会话、权限与越权、输入校验、SQL 拼接、CSRF/CORS、密码与密钥处理、依赖与标准库已知漏洞、CI 签名链路、容器与部署配置。
2. 渗透测试：在本机起隔离实例（独立数据库、独立端口、独立进程，不影响开发/生产环境）模拟攻击者，针对认证绕过、越权访问（IDOR）、CSRF、SQL 注入、路径穿越、JWT 篡改、限流绕过等做手工测试。

**范围说明**：未做资源耗尽 / 拒绝服务（DoS）类压测——这类测试本身有破坏性风险，且不在本次授权范围内；如需评估抗压能力，建议用专门的压测工具单独进行，并提前与基础设施一方约定窗口。

---

## 一、结论概览

| 编号 | 问题 | 等级 | 状态 |
|---|---|---|---|
| F1 | 管理后台登录限流可被客户端自带 `X-Real-IP` 绕过 | 中 | **已修复** |
| F2 | `go.mod` 声明的 Go 版本落后于实际构建镜像，标准库存在已被新版修复的 CVE | 低 | **已修复** |
| F3 | `npm audit` 此前因镜像源问题未能跑成 | 信息 | **已复核，0 漏洞** |
| F4 | refresh token 20 秒宽恕窗口削弱重放检测灵敏度 | 低 | 维持现状（刻意的工程取舍，用户决定不处理） |
| F5 | Android 全局 `usesCleartextTraffic="true"` | 低 | 维持现状（用户决定不处理） |

其余测试项（跨账号越权、CSRF、SQL 注入、路径穿越、JWT 完整性、密码哈希与常数时间比较、账号枚举时序、CSP/安全头、CORS、TLS、容器、更新签名链路）**均按预期拦截，未发现可利用漏洞**，详见第三节。

---

## 二、已修复问题详情

### F1【中危】管理后台登录限流依赖客户端可控的 `X-Real-IP` 头

- **位置**：`linkory-server/internal/admin/auth.go`（`sourceIP` / 登录限流逻辑）
- **原因**：登录失败限流原先只用 `sourceIP(r)` 作为计数 key；该函数在直连地址命中 `TrustedProxies`（默认 `127.0.0.1`/`::1`）时，会直接采信请求自带的 `X-Real-IP` 头。这个设计前提是"nginx 反代在本机、Go 只监听 127.0.0.1"，且 nginx 一定会用 `proxy_set_header X-Real-IP $remote_addr;` **覆盖**外部请求里原本的该头——生产部署脚本确实这样配置，但服务端本身没有任何兜底：一旦有路径能让请求直连到受信地址而不经过会覆盖该头的反代，限流就形同虚设。
- **复现**（修复前）：直连 loopback，每次请求带不同的 `X-Real-IP: 9.9.9.1` ~ `9.9.9.6`，连续 6 次管理员密码错误登录，全部返回 401（未被限流），因为每次"伪造 IP"在限流表里都是新的 key。
- **影响**：攻击者只需能从受信地址发起请求（同机其他进程、配置变更后的反代留口子等），就能对管理员账号做近乎无限次密码猜测。
- **修复方案**：登录失败限流改为同时在三个独立维度计数，命中任意一个即拒绝；验证通过时三者一并清空：
  1. `rawAddr`：Go 从 TCP 连接本身观察到的对端地址，**完全不读任何请求头**，不可能被一个请求的内容伪造；
  2. `sourceIP`：按原逻辑在受信代理场景下采信 `X-Real-IP`（用于准确记录真实客户端 IP，供审计使用）；
  3. 用户名（大小写无关）：即使攻击者每次都换一个"IP"，针对同一个管理员账号的失败次数依然会被累积限制。
  - 代码位置：`internal/admin/auth.go` 新增 `rawAddr()`、`recentLocked()`，`login()` 改为 `limitKeys := []string{"conn\x00"+rawAddr, "ip\x00"+sourceIP, "user\x00"+username}`。
- **验证**：新增测试 `TestAdminLoginRateLimitSurvivesSpoofedIP`（`internal/httpapi/admin_more_test.go`），复现"每次请求带不同伪造 `X-Real-IP`"的攻击场景，断言第 6 次返回 429；原有 `TestAdminLoginGuards` 等全部用例继续通过。手工复测：同样的伪造 IP 轮换脚本，第 6 次请求即被限流（429）。

### F2【低危】标准库版本落后，存在已修复的 CVE

- **位置**：`linkory-server/go.mod`（`go 1.26.3`）、`linkory-server/Dockerfile`（`golang:1.26.5-bookworm`）
- **原因**：`go.mod` 声明的最低 Go 版本早于实际构建镜像使用的版本，`govulncheck` 扫描出 14 个标准库 CVE（集中在 `net/http` 的 HTTP/2 相关拒绝服务/内存放大系列、`crypto/tls` 的 ECH 隐私泄露、`net/textproto`、`crypto/x509`），均已在 Go 1.26.4~1.26.9 修复。实际生产构建用的 Dockerfile 版本更新一些，风险主要在本机开发构建和未来 CI 镜像回退的场景。
- **修复方案**：
  - `go.mod` 的 `go` 指令提升到 `1.26.9`（本机 `GOTOOLCHAIN=auto` 会自动拉取并使用该版本，已验证可正常编译）；
  - `Dockerfile` 基础镜像同步提升到 `golang:1.26.9-bookworm`；
  - CI（`.github/workflows/release.yml` 的 `test` job）新增一步 `go run golang.org/x/vuln/cmd/govulncheck@latest ./...`，此后每次发版都会自动扫描标准库和依赖的已知漏洞，而不必等人工发现。
- **验证**：修复后重新运行 `govulncheck ./...`，14 个标准库 CVE 全部清零；`go vet ./...`、`go test ./...` 全部通过。剩余 1 条模块级提示（`golang.org/x/crypto@v0.57.0`，标注 "Fixed in: N/A"，官方尚无修复版本，代码未触达其漏洞点）留待上游发布补丁后跟进，不是本次可修复范围。

### F3【信息性】`npm audit` 复核

- **原因**：此前用 `npmmirror.com` 镜像源跑 `npm audit` 时返回 `404 /-/npm/v1/security/* not implemented`，未能得到结果。
- **处理**：改用官方 `registry.npmjs.org` 重新运行 `npm audit`（含开发依赖），结果为 **0 个漏洞**。`linkory-admin` 的生产依赖只有 `react`/`react-dom`/`lucide-react` 三个包，攻击面本身很小。

---

## 三、渗透测试结果明细

均为本地隔离实例上的手工单请求/低频测试（不含任何高并发压测）。

| 测试项 | 方法 | 结果 |
|---|---|---|
| 跨账号 IDOR | alice 尝试改名/删除 bob 的设备、把文件转发目标指向不属于自己的设备 ID | 全部 404，设备归属校验在 SQL `WHERE` 子句里完成，不区分"存在但无权"与"不存在" |
| JWT 完整性 | 静态分析 `alg=none`/篡改 `sub` 等场景 | `jwt.WithValidMethods(["HS256"])` 锁死算法；claims 里的 `sid+did+uid` 还要在数据库里命中一条活跃会话行，双重兜底 |
| refresh token 复用检测 | 拿到 token 后 refresh 一次，再重放旧 token | 窗口外复用会撤销设备全部会话（符合设计）；20 秒宽恕窗口内的行为见 F4 |
| 文件名路径穿越/异常输入 | `../../etc/passwd`、`..\..\win.ini`、`a/b.txt`、空文件名、300 字节超长文件名 | 全部 400 拒绝，分隔符与控制字符校验到位 |
| SQL 注入 | 对 `q=`、`status=` 等过滤参数构造 `' OR '1'='1` 等 payload | 全部参数化查询，未触发异常或绕过；接口本身在鉴权前就先 401 |
| 管理后台登录 CSRF | 伪造跨站 `Origin`、缺 `X-Linkory-Admin` 头 | 均 403，缺一不可 |
| 管理后台写接口 CSRF | 仅带 Cookie 不带 CSRF token / 带 token 不带 Origin / 三者齐全 | 前两种均 403，三者齐全才 204 成功 |
| 管理员账号枚举（时序） | 对比"未知用户名"与"已知用户名密码错误"各 5 次平均响应耗时 | 两者几乎一致（dummy hash 兜底生效），无明显时序侧信道 |
| `/metrics` 鉴权 | 无 token / 错误 token / 正确 token | 前两者 401；token 比较使用 `subtle.ConstantTimeCompare` |
| 敏感字段泄露 | 查看管理后台 `users`/`audit` 列表返回体 | 未包含 `password_hash` 等敏感字段 |
| 管理后台静态页安全头 | 检查 `Content-Security-Policy`、`X-Content-Type-Options` 等 | `script-src 'self'`（无 `unsafe-inline` 脚本）、`frame-ancestors 'none'`、`nosniff` 均存在 |
| 普通用户登录限流 | 同用户名+IP 组合 5 分钟内 5 次失败 | 第 6 次 429，符合设计 |
| 管理后台登录限流抗伪造（本次新增） | 伪造 `X-Real-IP` 轮换绕过 | 修复前可绕过（F1），修复后被 `rawAddr`/用户名维度拦住 |

---

## 四、架构 / 部署层面检查

- **CORS**：默认不配置 `LINKORY_CORS_ORIGINS` 时完全不反射 `Access-Control-Allow-Origin`；接口用 Bearer token 鉴权、不用 Cookie 鉴权，从不设置 `Access-Control-Allow-Credentials`，CSRF 面相应收窄。
- **CSP / 安全头**：网页版、管理后台、官网三处均有定制 CSP、`X-Content-Type-Options`、`Referrer-Policy`；管理后台额外有 `frame-ancestors 'none'`、`form-action 'self'`；nginx 生成配置里补了 HSTS。
- **TLS**：`ssl_protocols TLSv1.2 TLSv1.3`，无老协议；证书路径走变量化配置。
- **容器**：`Dockerfile` 非 root 用户运行（uid 10001）、`alpine` 基础镜像、多阶段构建不含源码/编译器、带 `HEALTHCHECK`。
- **密码哈希**：用户与管理员密码均为 Argon2id（m=64MB, t=2, p=1），参数合理；校验用 `subtle.ConstantTimeCompare`。
- **文件中转**：走内存 `io.Pipe`，不落盘、边转边算 SHA-256；接收端重新校验一遍，不信任发送端声称的哈希。
- **局域网直连鉴权**：HMAC 双向互证 + ChaCha20-Poly1305；`privateAddrs()` 把设备上报的直连地址严格限制在 loopback/私网/链路本地，防止被攻破的设备诱导对端连到任意公网地址。
- **应用内更新**：安装包下载后先验 `SHA256SUMS.txt.sig` 的 Ed25519 签名，再核对文件哈希；镜像加速站只是传输层，签名校验不依赖其可信度。
- **CI 签名密钥**：`UPDATE_SIGNING_KEY`、`ANDROID_KEYSTORE_*`、`MACOS_CERT_*`、`APPLE_*` 均走 GitHub Secrets，workflow 里私钥用完立即 `rm -f`，未发现密钥混入构建产物或日志。

---

## 五、维持现状的问题（用户决定不处理，记录存档）

### F4 refresh token 20 秒宽恕窗口

`internal/auth/service.go` 的 `RefreshGrace = 20*time.Second`：为容忍客户端网络重试，在刚失效的 refresh token 被重放时，20 秒内按"丢包重试"处理、返回同一个后继 token，而不是立即判定盗用并撤销整台设备。这是刻意的工程取舍（代码注释已说明），只在"攻击者能在 20 秒内截获到该 token"的极窄条件下降低重放检测灵敏度，不是实现缺陷。

### F5 Android `usesCleartextTraffic="true"`

`AndroidManifest.xml` 全局允许明文 HTTP，是为了支持用户自建服务器（`LINKORY_WEB_ALLOW_CUSTOM_SERVER` 场景）。官方服务器本身走 HTTPS，该配置只影响"用户主动选择自建服务器"的路径。

---

## 六、变更清单

- `linkory-server/internal/admin/auth.go`：登录限流改为 `rawAddr`/`sourceIP`/用户名三维度联合判定，新增 `rawAddr()`、`recentLocked()`。
- `linkory-server/internal/httpapi/admin_more_test.go`：新增 `TestAdminLoginRateLimitSurvivesSpoofedIP`。
- `linkory-server/go.mod`：`go 1.26.3` → `go 1.26.9`。
- `linkory-server/Dockerfile`：`golang:1.26.5-bookworm` → `golang:1.26.9-bookworm`。
- `.github/workflows/release.yml`：`test` job 新增 `govulncheck` 扫描步骤。

全部变更已通过 `go vet ./...`、`go test ./...`（含真实 MySQL 集成测试）、`govulncheck ./...`（标准库 0 漏洞）、`npm audit`（官方源，0 漏洞）、`actionlint`（CI 配置语法检查）验证。
