import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../core/store.dart';
import '../../core/realtime.dart';
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

/// Shared home page: introduction for guests, status and quick actions when signed in.
class GuestWelcome extends ConsumerWidget {
  const GuestWelcome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final guest = ref.watch(isGuestProvider);
    final session = ref.watch(sessionProvider);
    final st = ref.watch(storeProvider);
    final store = ref.read(storeProvider.notifier);
    final peers = st.devices.where((d) => !d.current).toList();
    final onlineCount = peers.where((d) => st.isOnline(d.id)).length;
    final connection = switch (st.link) {
      LinkState.connected => '已连接',
      LinkState.connecting => '正在连接',
      LinkState.reconnecting => '正在重连',
      LinkState.closed => '未连接',
    };
    Widget statusRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: Type.caption.copyWith(color: c.text3))),
        Expanded(child: Text(value, style: Type.body.copyWith(color: c.text1))),
      ]),
    );
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
        child: Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const BrandLogo(size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(guest ? '欢迎使用连信' : '欢迎回来，${session.username}', style: Type.page.copyWith(color: c.text1)),
                      Text('跨越距离，自由传递。', style: Type.body.copyWith(color: c.text3)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 20),
                if (!guest) ...[
                  PanelCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      statusRow('当前账号', session.username),
                      statusRow('服务连接', connection),
                      statusRow('其他设备', '$onlineCount 台在线 / ${peers.length} 台已关联'),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    LButton(label: '发送消息', icon: LucideIcons.messageSquare,
                      variant: BtnVariant.solid,
                      onPressed: peers.isEmpty ? null : () {
                        final target = peers.firstWhere((d) => st.isOnline(d.id), orElse: () => peers.first);
                        store.openConversation(target.id);
                      }),
                    LButton(label: '传输中心', icon: LucideIcons.arrowLeftRight,
                      onPressed: () => store.setSection(Section.transfers)),
                    LButton(label: '管理设备', icon: LucideIcons.laptop,
                      onPressed: () => store.setSection(Section.devices)),
                  ]),
                  const SizedBox(height: 8),
                  Text(peers.isEmpty
                    ? '在另一台设备上登录同一账号，即可开始互发消息和文件。'
                    : '也可以从左侧选择设备，开始发送消息或文件。',
                    style: Type.caption.copyWith(color: c.text3)),
                  const SizedBox(height: 20),
                ],
                LayoutBuilder(builder: (context, box) {
                  final columns = box.maxWidth >= 640 ? 2 : 1;
                  final width = (box.maxWidth - (columns - 1) * 24) / columns;
                  final features = <Widget>[
feature(LucideIcons.messageSquare, '跨网络互发消息', '连接同一服务器后，异地设备也能互发文字、链接与剪贴板，无需处于同一局域网；离线消息上线补发。'),
                feature(LucideIcons.arrowLeftRight, '便捷传输文件', '拖进窗口即可发送，跨网络也能传输；中转文件仅流式转发，不在服务端落盘。'),
                feature(LucideIcons.lockKeyhole, '加密直连，减少中转', '局域网文件优先 P2P 加密直连，失败自动回退中转；接收端校验文件完整性。'),
                feature(LucideIcons.server, '选择适合你的服务', '可使用官方中转，也可连接自己部署的连信服务器。'),
                  ];
                  return Wrap(
                    spacing: 24,
                    runSpacing: 8,
                    children: [for (final item in features) SizedBox(width: width, child: item)],
                  );
                }),
                if (guest) ...[
                const SizedBox(height: 16),
                Row(children: [
                  LButton(label: '登录', variant: BtnVariant.solid, onPressed: () => showLogin(context)),
                  const SizedBox(width: 8),
                  LButton(label: '注册账号', onPressed: () => showLogin(context, register: true)),
                ]),
                const SizedBox(height: 10),
                Text('未登录时可以浏览界面和调整设置，但不会与其他设备互联。', style: Type.caption.copyWith(color: c.text3)),
                ],
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
