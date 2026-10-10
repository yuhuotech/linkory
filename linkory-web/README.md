# 连信官网

独立静态站点：原生 HTML / CSS / JavaScript，无框架、无安装步骤、无构建步骤、无后台服务。页面资源全部本地化；系统字体，无第三方字体、统计或组件 CDN。唯一外部请求是 GitHub Releases API，用于获取最新正式版安装包；请求失败或禁用 JS 时，下载按钮回退到 Releases 页面。

## 本地预览

在本目录执行：

```sh
python3 -m http.server 4173
```

打开 http://localhost:4173 。也可直接打开 index.html，建议用 HTTP 预览。

## Vercel

导入 `yuhuotech/linkory` 仓库，设置：

- Root Directory：`linkory-web`
- Framework Preset：`Other`
- Build Command：留空（覆盖为无构建）
- Output Directory：`.`
- Install Command：留空（不需要依赖安装）

`vercel.json` 设置安全响应头和图片缓存。部署域名在 Vercel 项目中配置，无需改代码。没有 SPA 路由，不需要 rewrite。

## 自有服务器

将本目录里的 `index.html`、`styles.css`、`script.js`、`assets/` 上传到静态根目录即可。生产环境配置 HTTPS，示例 nginx：

```nginx
server {
    listen 80;
    server_name example.com; # 替换为官网域名
    root /var/www/linkory-web;
    index index.html;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header X-Frame-Options DENY always;
    location / { try_files $uri $uri/ =404; }
    location /assets/ { expires 1d; }
}
```

HTTPS 可通过已有反向代理或 Certbot 配置。`vercel.json` 不影响 nginx。

## 内容维护

- 产品文案在 `index.html`，样式在 `styles.css`，预览主题切换和下载逻辑在 `script.js`。
- 安装包地址实时读取最新正式 Release，不固定版本号，不提供不存在的 iOS 下载。
- 官方主域名 `https://linkory.yuhuotech.com`；旧地址 `https://linkory.dev99.cn` 保留为同一服务的兼容域名。页面 canonical 指向主域名，旧域名不强制跳转。
- 当前未送达文字消息默认超过 30 天后清理，已送达历史尚无自动过期；中转文件不落盘；加密直连限局域网文件。不要把这些描述扩展为所有消息端到端加密或服务器不存消息。
- 截图复制自 `docs/images/`，品牌图标来自 `assets/brand/`。源文件更新后同步复制到本目录，不依赖上级目录，保证独立部署。
- 所有图片是应用真实界面；功能区小型消息／文件示意仅作展示，文件进度注明演示。
- 设置最终域名后，可补充 canonical、绝对地址 og:image 与 sitemap。

## 验证

```sh
node --check script.js
node tests/download.test.cjs
```

浏览器检查桌面／手机宽度、浅深预览切换、FAQ、下载正常和 GitHub API 不可用时的回退。

## 隐私与协议页面

`privacy.html` / `terms.html` 为独立静态页面，首页及两个文档页底部均有入口。使用用户确认的运营信息：与或科技、linkory@yuhuotech.com、官方业务服务器位于中国。官网托管和第三方下载访问与业务数据库分开说明。

技术描述已核对 `linkory-server/internal/messaging/store.go` 的 `PurgeExpired`、auth/device/transfer 存储、客户端 `deleteMessage` 与 `log.dart`。注意 30 天规则只清理未送达消息，移除设备是撤销访问，删除消息是本地隐藏；当前没有自助注销接口。

正式开放官方服务前，核对实际日志／备份配置并补充确定的期限；页面没有虚构已实现的协议勾选或注销功能。后续接入客户端注册确认时，应另行实现入口、明确确认和必要的版本记录。本次仅新增官网页面。

编写参考：
- 《个人信息保护法》：https://www.cac.gov.cn/2021-08/20/c_1631050028355286.htm
- 《民法典》：https://www.spp.gov.cn/zdgz/202006/t20200602_463886.shtml

页面是按当前实现和运营信息编写的产品文本，不表示已完成针对实际部署的法律审查。
