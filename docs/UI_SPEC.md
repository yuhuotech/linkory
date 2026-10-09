# Linkory UI 规范

> 来源：完整移植 [cc-switch](https://github.com/farion1231/cc-switch)（v7 设计系统：`src/index.css`、`tailwind.config.cjs`、`Sidebar`、`ProviderCard`、`AppPageHeader`、`button/badge/input/tabs`）。
> **唯一的结构性差异**：cc-switch 桌面端是「侧栏 | 内容」两栏，Linkory 改为微信式三栏「图标栏 | 列表栏 | 内容区」。
> 代码事实来源：`linkory-app/lib/theme/tokens.dart`（token）、`linkory-app/lib/shared/widgets.dart`（控件）、`linkory-app/lib/features/shell/shell.dart`（布局）。
> 本文与代码冲突时以本文为设计意图，应修正代码或更新本文，二者必须同步。

## 1. 总原则

1. **只用 token**：颜色走 `context.c.xxx`，字号走 `Type.xxx`，圆角走 `Radii.xxx`。禁止在页面代码中写 `Color(0x...)`、裸 `fontSize`、裸圆角数值。
2. **只用共享控件**：按钮、输入框、徽标、页头、卡片、悬停行都用 `shared/widgets.dart` 里的控件；缺少的先加到那里再用。
3. **深浅色都要对**：每个新界面都要在两套主题下检查；颜色不要靠透明度叠加推算，使用 token 里成对的 `*Soft`、`*Text`。
4. **克制**：一个视图最多一个实心橙色主按钮，其余用 neutral/quiet/ghost。没有蓝色/绿色按钮，没有渐变，没有大面积彩色块。
5. **文案**：界面语言中文，简短直白；错误提示给出原因与下一步。

## 2. 颜色

主题色（action）为橙色。语义色：`direct`（蓝，信息/在线直连类）、`success`、`warning`、`danger`。每个语义色有三个成员：实心 `x`、文字用 `xText`（保证对比度）、背景 `xSoft`。

| Token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| bgApp | #FFFFFF | #1C1C1E | 内容区背景 |
| bgSidebar | #F5F5F7 | #161618 | 图标栏、列表栏背景 |
| bgSubtle | #EFEFF2 | #26262A | 悬停背景、次级填充 |
| bgSelected | #E4E4EA | #313136 | 选中行背景 |
| bgCard | #FFFFFF | #2E2E33 | 卡片背景 |
| border | #E4E4E8 | #3E3E45 | 分隔线、卡片边框 |
| borderStrong | #CFCFD6 | #4A4A52 | neutral 按钮、输入框边框 |
| text1 / text2 / text3 | #18181B / #52525B / #65656E | #F4F4F5 / #D0D0D8 | 主文字 / 次文字 / 辅助文字（text3 深色 #B5B5BD） |
| action | #F97316 | #EA580C | 主按钮、选中强调、徽标 |
| actionHover | #EA620A | #F06D1F | 主按钮悬停 |
| actionText | #C2410C | #FB923C | 橙色文字/链接 |
| actionSoft | #FFF1E6 | 橙 12% | 橙色浅底 |
| controlOff | #888890 | #6F6F77 | 开关关闭态 |
| direct / directText / directSoft | #0A84FF / #0063C7 / #EAF3FF | #4A8FD9 / #8FB8E6 / 蓝 12% | 信息 |
| success / Text / Soft | #16A34A / #007634 / #E8F7EE | #4ADE80 / #4ADE80 / #0F2B1A | 在线、完成 |
| warning / Text / Soft | #D97706 / #A64A00 / #FEF3C7 | #FBBF24 / #FCD34D / #33260A | 校验中、警告 |
| danger / Text / Soft | #DC2626 / #B91C1C / #FEE2E2 | #F87171 / #FCA5A5 / #3A1414 | 失败、删除 |
| overlay | #09090B 36% | #000000 55% | 对话框遮罩 |

阴影：`shadowSm`（卡片静止）、`shadowMd`（悬停/浮层）、`shadowLg`（对话框），均按浅/深色分别定义。

## 3. 字体与字号

字体族：系统 UI 字体回退链（`.AppleSystemUIFont` → PingFang SC → Segoe UI/微软雅黑 → Roboto…），等宽用 SF Mono/Menlo/Consolas。不引入自定义字体。

| Token | 字号/行高 | 字重 | 用途 |
|---|---|---|---|
| Type.badge | 11/16 | 500 | 徽标、角标、极小说明 |
| Type.caption | 12/18 | 400 | 时间、次要说明、列表第二行 |
| Type.body | 13/20 | 400 | **默认正文**、按钮文字（按钮用 500） |
| Type.strong | 14/20 | 500 | 列表项标题、强调正文 |
| Type.section | 15/22 | 600 | 区块标题 |
| Type.title | 16/24 | 600 | 对话框标题、卡片大标题 |
| Type.page | 18/26 | 600 | 页面标题（页头） |
| Type.metric | 24/32 | 600 | 数字指标 |

## 4. 圆角、间距、尺寸

- 圆角：control **6**（按钮、输入框、导航项、悬停行）、panel **10**（卡片、设备头像）、dialog **14**（对话框、浮层）；徽标为全圆角胶囊。
- 间距以 4 的倍数为主：4 / 8 / 12 / 16 / 24。页面内容边距 24；列表项水平内边距 8（外）+10（内）；卡片内边距 16。
- 控件高度：按钮 regular **32** / compact **28**；图标按钮 28 或 32 见方；输入框 32；徽标高 18；导航项高 28（列表栏内的次级导航）。
- 分隔：1px，`border` 色；栏与栏之间用 1px 竖线，不用阴影。
- 图标：Lucide（`lucide_icons_flutter`），默认 16px，导航 18–20px；线宽跟随 cc-switch（1.5）；颜色默认 text2，选中 text1/action。

## 5. 三栏布局（与 cc-switch 的差异所在）

```
┌──────┬────────────┬───────────────────────────────┐
│ 72px │   280px    │          自适应               │
│ 图标 │  列表栏    │  页头 52px                    │
│ 栏   │ (会话/设备 │  ─────────────────────────    │
│      │  /任务…)   │  内容区                       │
│      │            │                               │
└──────┴────────────┴───────────────────────────────┘
```

- **图标栏**（72px，`bgSidebar`）：顶部留 44px 给 macOS 红绿灯（可拖拽区）；其下 28×28 橙底白色双环品牌 Logo（共享控件 `BrandLogo`，固定品牌色，资源自带圆角）；导航按钮 48×32、间隔 4，选中为 `bgSelected` 底 + text1 图标，未选中 text2，悬停 `bgSubtle`；活动传输数用橙色角标（高 14，字号 10）；底部依次为连接状态点（8px 圆点：success/warning/danger）与「设置」。
- **列表栏**（280px，`bgSidebar`）：顶部搜索/标题区，其下列表；行为 `HoverRow`，选中 `bgSelected`，悬停 `bgSubtle`，圆角 6；行内：头像（`DeviceGlyph` 圆角 10，右下角在线点 11px、描边为 `bgSidebar` 2px）+ 标题（Type.strong）+ 第二行（Type.caption，text3）+ 右侧时间/未读徽标。
- **内容区**（`bgApp`）：`PageHeader`（高 52，左内边距 24 右 16，标题 Type.page，右侧 actions 间距 8）；下方为页面内容。
- 栏与栏之间 1px 竖线（`border`）。窗口最小宽度需容纳 72+280+内容区 ≥ 360；窄屏（移动端，阶段 07）折叠为单栏 + 底部导航，token 与控件保持不变。
- 导航与选中状态是全局的（`AppStore.section`），列表栏内容随图标栏选择切换：设备会话 → 设备列表（在线状态+最近消息）；设备管理 → 设备项；传输中心 → 过滤分组；设置 → 设置分组。

## 6. 控件规范

- **按钮 `LButton`**：变体 `solid`（橙色实心，白字 600，页头主操作，每视图唯一）、`neutral`（描边，默认）、`quiet`（透明，页头次要操作）、`ghost`（仅文字，悬停 subtle）、`destructive`（danger 实心）。尺寸 32/28；内边距水平 14/12；图标与文字间距 6；按下缩放到 0.96；禁用 50% 透明（neutral 禁用为透明底 + text3）；加载中显示 14px 转圈替换图标。
- **图标按钮 `LIconButton`**：28/32 见方，悬停 `bgSubtle`，圆角 6。
- **输入框 `LTextField`**：高 32，圆角 6，边框 `borderStrong`，聚焦边框 action；错误边框 danger；占位文字 text3。
- **徽标 `LBadge`**：高 18、水平内边距 6、胶囊，Type.badge；中性 `bgSubtle`+text2，其余用 `xSoft` 底 + `xText` 字。
- **卡片 `PanelCard`**：`bgCard`、1px `border`、圆角 10、内边距 16、`shadowSm`；悬停 `shadowMd`；选中/活跃时边框用 action。
- **对话框**：圆角 14、`shadowLg`、遮罩 `overlay`；标题 Type.title；底部按钮右对齐，主按钮 solid，取消 neutral/quiet。
- **提示 SnackBar**：floating，宽 360，错误文案原因优先。
- **状态表达**：在线 success 圆点；传输中 action；校验中 warning；完成 success；失败/取消用 danger 文字或 dangerSoft 底徽标。不要仅靠颜色，必须配文字或图标。
- **交互反馈**：悬停变底色（无水波纹，主题已关闭 splash/highlight）；点击缩放 0.96；动画时长 ≤150ms。

## 7. 页面清单与约定

| 页面 | 列表栏 | 内容区 |
|---|---|---|
| 登录/注册 | — | 居中卡片（宽约 360），品牌方块 + 标题 + 表单 + 唯一 solid 按钮 |
| 设备会话 | 设备列表 | 页头（设备名+在线徽标）、消息气泡流、底部输入区（发送文字/选择文件） |
| 设备管理 | 本账号设备 | 设备详情卡片：重命名、移除（destructive，需确认） |
| 传输中心 | 状态过滤 | 传输卡片：文件名、大小、进度条（action）、状态徽标、操作按钮 |
| 设置 | 设置分组 | 分组卡片：服务器地址、下载目录、主题（浅/深/跟随系统）、退出登录 |

消息气泡：自己发送用 `actionSoft` 底 + text1，对方用 `bgSubtle` 底 + text1；圆角 10；正文 Type.body；时间 Type.caption text3；发送中/失败状态在气泡旁用图标 + 文字，失败可点击重试。

## 8. 验证与维护

- 新增或修改界面后：`flutter analyze`、`flutter test`；视觉变化需更新 golden（`flutter test --update-goldens`）并检查 `test/goldens/*.png`，浅色与深色都要覆盖。
- 修改 token 只改 `lib/theme/tokens.dart` 与本文的同一处，不在页面里局部覆盖。
- 若要参考 cc-switch 的细节，对照其 `src/index.css`、`tailwind.config.cjs` 及组件源码（`Sidebar.tsx`、`ProviderCard.tsx`、`AppPageHeader.tsx`、`ui/button.tsx`）；不确定时优先与 cc-switch 保持一致，再按三栏做最小适配。
- 当前尚未做逐像素对照 cc-switch 官方界面，也没有在真机 macOS 上看过；待 Xcode 就绪后补充。

## 9. 品牌与平台图标

品牌源文件为 `assets/brand/linkory-logo.svg`，运行 `python3 tools/gen_icons.py` 一次生成所有平台资源。登录页与图标栏统一使用 `BrandLogo`；Logo 保持 #F97316，不随深浅主题改变品牌色。

macOS AppIcon 同时用于 Finder、Dock 与系统应用入口；菜单栏使用 18pt/2x 透明单色模板，由系统适配深浅色。Windows 使用多尺寸 ICO（应用、任务栏及托盘）；Linux 窗口及托盘使用彩色 PNG。iOS 使用不透明 RGB 图标，Android 提供传统及自适应图标，Web 提供 favicon 与安全区内的 maskable 图标。Linux 启动器图标仍需安装包注册 .desktop 文件（当前尚无 Linux 安装包）。

## 9. 窄屏（移动端）布局

窗口宽度 < 720（`narrowBreakpoint`，`isNarrow(context)`）时折叠为单栏，token 与控件不变：

- 主区域一次只显示一个页面：会话 / 设备 / 设置显示列表栏内容（全宽），传输直接显示传输中心（页头下方是横向滚动的过滤按钮）。
- 点击列表项用 `Navigator.push` 打开 `DetailPage`（会话、设备详情、设置项）；`PageHeader` 在可返回时自动显示 32px 返回按钮，左内边距缩为 8。
- 底部导航 `_BottomNav`：`bgSidebar` 底 + 顶部 1px `border`；4 项（会话/设备/传输/设置）高 52，图标 20 + 11px 标签，选中色 `actionText`，传输项带橙色活动数角标；底部预留系统安全区。
- 内容页顶部使用 `SafeArea`；不使用隐藏标题栏与窗口拖拽区（`DragArea` 仅桌面）。
- 新页面必须同时在宽屏和窄屏下检查；窄屏用 `test/shell_test.dart` 的 narrow 用例与 `goldens/narrow_*.png` 覆盖。

## 10. 其他共享控件

- `LSwitch`：36×20 开关，开启为 `action`，关闭为 `controlOff`，圆点 16。
- `LDialog` / `ConfirmDialog`：圆角 14、20 内边距、右对齐按钮（取消 neutral，确认 solid 或 destructive）。
- `DragArea`：隐藏标题栏时的窗口拖拽区；**不要**给它加双击手势（祖先的双击识别器会让内部所有按钮延迟约 300ms）。
- 传输卡片：左对齐为收到、右对齐为发出；走局域网直连时显示 `LBadge('局域网直连')`；传输中显示速度与耗时。

## 11. 未登录（浏览模式）

应用启动**不强制登录**：未登录时同样显示完整三栏/单栏界面，只是不与任何设备互联（`isGuestProvider`）。

- 默认内容页是 `GuestWelcome`（功能介绍 + 登录/注册入口），不是登录表单。
- 登录/注册是按需打开的对话框 `showLogin(context, register:)`（`LoginCard`），成功后自动关闭并开始连接；`LoginPage` 仅作独立页面备用。
- 每个依赖账号的区域都要有「说明 + 登录入口」的空状态：会话列表用 `GuestEmpty`，设备页与传输中心页头下方用 `GuestBanner`（`actionSoft` 底、`actionText` 字、右侧 solid 登录按钮）。
- 设备页显示本机（`guestDeviceProvider`，状态徽标「未登录」，设备 ID 等服务端字段显示占位）；重命名、刷新等需要服务端的操作禁用；左侧栏状态点为灰色，提示「未登录」。
- 设置页全部可用：账号页显示未登录状态与登录/注册按钮；通用、传输、关于照常可改。
- 退出登录后停留在当前页面，回到浏览模式；新增依赖账号的功能时，必须同时提供未登录时的说明与登录入口，不能让入口消失或空白。

## 12. 传输卡片与接收设置

- 文件卡片的「打开文件」「在文件夹中显示」用两个 28px 图标按钮（`externalLink`、`folderOpen`，带 tooltip），不用文字按钮，避免卡片过宽。发出的文件在任何状态都可打开（源文件）；收到的文件完成后才可打开。文件被移动或删除时提示「文件已被移动或删除」。手机端暂不显示（没有可靠的跨应用打开方式）。
- 设置 → 传输 →「接收文件」是开关，**默认自动接收**：收到文件邀请时不再需要点「接收」，直接开始接收（邀请只会来自同一账号的设备）。关闭后恢复卡片上的「接收 / 拒绝」按钮。通知文案随之变为「正在接收…」或「…想发送文件」。

## 13. 窗口控制（无边框窗口）

标题栏统一隐藏以保持界面干净。macOS 保留系统红绿灯（浮在图标栏顶部的 44px 空白处）；**Windows / Linux 在页头最右侧自绘最小化、最大化/还原、关闭三个按钮**（`WindowControls`，`hasCustomWindowControls`），它们只出现在内容区页头里，与 `actions` 之间用 1px 竖线分隔：

- 按钮 32×28、圆角 6、图标 12–15px；常态 `text2`，悬停 `bgSubtle` + `text1`；关闭悬停为 `dangerSoft` + `dangerText`。
- 页头空白处可拖动窗口，双击最大化/还原（用原始指针事件检测，不使用双击识别器，避免页头按钮被延迟）。
- Linux 无边框窗口没有系统缩放边框：在 `MaterialApp.builder` 里包 `DragToResizeArea` 提供四边四角的缩放热区。
- Linux 的「关闭窗口时最小化到托盘」默认关闭（GNOME 默认不显示托盘图标，窗口藏起来就找不回了）；macOS/Windows 默认开启，可在 设置 → 通用 修改。
- 新页面必须使用 `PageHeader`，不要自己拼页头，否则会缺少窗口按钮和拖动区。
- 「关闭到托盘」= 窗口隐藏 + 从 Dock / 任务栏移除（`hideToTray`：`hide` 后 `setSkipTaskbar(true)`，macOS 上应用切到 accessory 模式），进程、连接和托盘图标继续运行；从托盘图标/菜单、通知点击恢复（`showWindow` 先恢复 Dock 条目再显示）。Cmd+Q / 托盘「退出」才真正退出。Linux 若开启此项，需要桌面环境显示托盘（GNOME 需 AppIndicator 扩展），否则窗口无法找回。

