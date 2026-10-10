## 下载

| 系统 | 推荐下载 | 说明 |
|---|---|---|
| Windows 10/11 | [`Linkory-{{V}}-windows-x64-setup.exe`](https://github.com/{{REPO}}/releases/download/{{TAG}}/Linkory-{{V}}-windows-x64-setup.exe) | 安装程序，无需管理员权限。也提供免安装的 [zip](https://github.com/{{REPO}}/releases/download/{{TAG}}/Linkory-{{V}}-windows-x64.zip)。暂未代码签名，首次运行若出现 SmartScreen 提示，点「更多信息 → 仍要运行」 |
| macOS（Apple 芯片） | [`Linkory-{{V}}-macos.dmg`](https://github.com/{{REPO}}/releases/download/{{TAG}}/Linkory-{{V}}-macos.dmg) | 已签名并通过 Apple 公证，拖入「应用程序」即可打开 |
| Linux（x64） | [`Linkory-{{V}}-linux-amd64.deb`](https://github.com/{{REPO}}/releases/download/{{TAG}}/Linkory-{{V}}-linux-amd64.deb) | `sudo apt install ./Linkory-{{V}}-linux-amd64.deb`；也提供 [tar.gz](https://github.com/{{REPO}}/releases/download/{{TAG}}/Linkory-{{V}}-linux-x64.tar.gz) |
| Android | [`Linkory-{{V}}-android.apk`](https://github.com/{{REPO}}/releases/download/{{TAG}}/Linkory-{{V}}-android.apk) | 安装时需允许「安装未知来源应用」 |
| iOS | — | 需要 Apple 开发者签名，暂未提供 |

> 已经装过旧版？在应用的「设置 → 软件更新」里一键更新即可。访问 GitHub 慢时，可把下载源切到「国内加速」，安装包仍由官方签名校验。

## 更新内容

{{CHANGES}}

## 自建服务端

客户端需要连接一个服务端才能互发消息。下载 `linkory-server-{{V}}-<系统>-<架构>` 是一个 Go 单文件程序，部署方法见 [`docs/DEPLOYMENT.md`](https://github.com/{{REPO}}/blob/{{TAG}}/docs/DEPLOYMENT.md)。

## 校验

`SHA256SUMS.txt` 列出了所有文件的 SHA-256，`SHA256SUMS.txt.sig` 是它的 Ed25519 签名（应用内更新据此验证）。
