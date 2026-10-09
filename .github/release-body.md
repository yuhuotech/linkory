## 安装包

| 平台 | 文件 | 说明 |
|---|---|---|
| Windows (x64) | `Linkory-<版本>-windows-x64-setup.exe` | 安装程序（无需管理员权限，可选安装目录）；另有 `…-windows-x64.zip` 免安装版 |
| macOS (Apple 芯片) | `Linkory-<版本>-macos.dmg`（`…-macos.zip` 供应用内更新使用） | **未签名**：首次打开请右键 →「打开」，或执行 `xattr -cr "/Applications/连信 Linkory.app"` |
| Linux (x64) | `Linkory-<版本>-linux-amd64.deb`、`…-linux-x64.tar.gz` | `sudo apt install ./Linkory-*.deb`；tar.gz 解压后运行 `linkory_app` |
| Android | `Linkory-<版本>-android.apk` | 使用测试签名，仅用于安装试用 |
| 服务端 | `linkory-server-<版本>-<系统>-<架构>.tar.gz/zip` | Go 单文件程序，部署见仓库 `docs/DEPLOYMENT.md` |

校验：`SHA256SUMS.txt`（附 Ed25519 签名 `SHA256SUMS.txt.sig`，应用内更新据此验证）。

**应用内更新**：设置 → 软件更新，或侧栏出现的「发现新版本」提示，可一键下载、校验并安装（Windows 安装版、macOS 放在「应用程序」中、Linux 的 .deb 安装版、Android 均支持；其余情况会引导到本页手动下载）。访问不了 GitHub 时，可在更新对话框或设置里把下载源切换为「国内加速」（gh-proxy.com / ghfast.top），安装包仍由官方签名校验。

## 使用

1. 先部署服务端（Docker 或二进制），客户端登录时填写服务端地址。
2. 同一账号在多台设备登录后，设备会互相出现；局域网内文件自动走直连。

> iOS 需要 Apple 开发者签名，暂未提供安装包。
