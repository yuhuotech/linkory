## 安装包

| 平台 | 文件 | 说明 |
|---|---|---|
| Windows (x64) | `Linkory-<版本>-windows-x64-setup.exe` | 安装程序（无需管理员权限，可选安装目录）；另有 `…-windows-x64.zip` 免安装版 |
| macOS (Apple 芯片) | `Linkory-<版本>-macos.dmg` | **未签名**：首次打开请右键 →「打开」，或执行 `xattr -cr "/Applications/连信 Linkory.app"` |
| Linux (x64) | `Linkory-<版本>-linux-amd64.deb`、`…-linux-x64.tar.gz` | `sudo apt install ./Linkory-*.deb`；tar.gz 解压后运行 `linkory_app` |
| Android | `Linkory-<版本>-android.apk` | 使用测试签名，仅用于安装试用 |
| 服务端 | `linkory-server-<版本>-<系统>-<架构>.tar.gz/zip` | Go 单文件程序，部署见仓库 `docs/DEPLOYMENT.md` |

校验：`SHA256SUMS.txt`。

## 使用

1. 先部署服务端（Docker 或二进制），客户端登录时填写服务端地址。
2. 同一账号在多台设备登录后，设备会互相出现；局域网内文件自动走直连。

> iOS 需要 Apple 开发者签名，暂未提供安装包。
