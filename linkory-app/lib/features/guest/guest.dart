import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/widgets.dart';
import '../../theme/tokens.dart';
import '../auth/login_page.dart';

/// Shown above the content while signed out: everything can be explored, nothing is connected.
class GuestBanner extends StatelessWidget {
  const GuestBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: c.actionSoft, border: Border(bottom: BorderSide(color: c.border))),
      child: Row(children: [
        Icon(LucideIcons.info, size: 14, color: c.actionText),
        const SizedBox(width: 8),
        Expanded(child: Text('当前未登录：登录后才能与你的其他设备互联、收发消息和文件。', style: Type.caption.copyWith(color: c.actionText))),
        const SizedBox(width: 8),
        LButton(label: '登录', compact: true, variant: BtnVariant.solid, onPressed: () => showLogin(context)),
      ]),
    );
  }
}

/// Empty state with a sign-in action, for lists and pages that need an account to have content.
class GuestEmpty extends StatelessWidget {
  const GuestEmpty({super.key, required this.icon, required this.title, required this.message, this.compact = false});
  final IconData icon;
  final String title, message;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: compact ? 28 : 40, color: c.borderStrong),
          const SizedBox(height: 12),
          Text(title, style: Type.strong.copyWith(color: c.text1), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(message, style: Type.caption.copyWith(color: c.text3), textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Row(mainAxisSize: MainAxisSize.min, children: [
            LButton(label: '登录', variant: BtnVariant.solid, onPressed: () => showLogin(context)),
            const SizedBox(width: 8),
            LButton(label: '注册', onPressed: () => showLogin(context, register: true)),
          ]),
        ]),
      ),
    );
  }
}

/// Default content page when signed out: what the app does and how to get started.
class GuestWelcome extends StatelessWidget {
  const GuestWelcome({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget feature(IconData icon, String title, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: c.bgSubtle, borderRadius: BorderRadius.circular(Radii.panel), border: Border.all(color: c.border)),
              child: Icon(icon, size: 18, color: c.text2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Type.strong.copyWith(color: c.text1)),
                const SizedBox(height: 2),
                Text(text, style: Type.caption.copyWith(color: c.text3)),
              ]),
            ),
          ]),
        );
    return Column(children: [
      const PageHeader(title: '连信'),
      Expanded(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const BrandLogo(size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('欢迎使用连信', style: Type.page.copyWith(color: c.text1)),
                      Text('跨越距离，自由传递。', style: Type.body.copyWith(color: c.text3)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 20),
                feature(LucideIcons.messageSquare, '设备间互发消息', '文字、链接和剪贴板内容，对方离线也会在上线后补发。'),
                feature(LucideIcons.arrowLeftRight, '传输文件', '拖进窗口即可发送；同一局域网内自动直连，否则走服务端中转，接收端校验完整性。'),
                feature(LucideIcons.laptop, '管理你的设备', '同一账号登录的设备会自动出现在列表中，可重命名或移除。'),
                feature(LucideIcons.shieldCheck, '自建服务，数据自己掌握', '登录时填写你自己部署的服务端地址即可。'),
                const SizedBox(height: 16),
                Row(children: [
                  LButton(label: '登录', variant: BtnVariant.solid, onPressed: () => showLogin(context)),
                  const SizedBox(width: 8),
                  LButton(label: '注册账号', onPressed: () => showLogin(context, register: true)),
                ]),
                const SizedBox(height: 10),
                Text('未登录时可以浏览界面和调整设置，但不会与其他设备互联。', style: Type.caption.copyWith(color: c.text3)),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
