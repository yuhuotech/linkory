# 连信 Linkory 品牌文件

连信用于同一账号下多设备之间互发文字和文件。Logo 延续项目已有的双环连接标识：两个相连的环代表设备互联，也呼应 Linkory 的 Link；橙色沿用 UI 主题色 #F97316。图形保持简洁，适合桌面图标与小尺寸品牌入口。

## 文件

- `linkory-logo.svg`：正式矢量图标，橙底白环，圆角外侧透明。
- `linkory-logo-{32,64,128,256,512,1024}.png`：透明背景 PNG 图标。
- `linkory-mark.svg`：透明底橙色符号。
- `linkory-mark-white.svg` / `linkory-mark-black.svg`：单色符号，用于深色背景或单色印刷。
- `linkory-wordmark-light.svg`：浅色背景组合标志。
- `linkory-wordmark-dark.svg`：深色背景组合标志。
- `preview.html`：深浅背景与小尺寸预览，可直接用浏览器打开。

## 使用

优先使用 SVG，图标最小建议 24px；外侧保留至少图标宽度 1/8 的空白。保持比例，不加渐变、阴影或拉伸。组合标志含可编辑系统字体文字，不同系统字形可能略有差异；印刷定稿时应在设计软件中将文字转为轮廓。

已集成客户端品牌入口、各平台应用图标和桌面托盘。运行 `python3 tools/gen_icons.py` 可从 SVG 源文件重新生成平台图标；平台说明见 `docs/UI_SPEC.md`。
