import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/desktop.dart';
import '../../core/models.dart';
import '../../core/realtime.dart';
import '../../core/store.dart';
import '../../core/updater.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';
import '../../core/session.dart';
import '../chat/chat_view.dart';
import '../devices/devices_view.dart';
import '../guest/guest.dart';
import 'toast.dart';
import '../settings/settings_view.dart';
import '../update/update_ui.dart';
import '../transfers/transfers_view.dart';

const railWidth = 72.0;
const listWidth = 280.0;

/// WeChat-style three columns, drawn with cc-switch's sidebar/page tokens:
/// icon rail | list panel | content.
class Shell extends ConsumerWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    ref.listen(storeProvider.select((s) => s.error), (_, e) {
      if (e != null) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(e), behavior: SnackBarBehavior.floating, width: 360));
        ref.read(storeProvider.notifier).clearError();
      }
    });
    if (isNarrow(context)) return _NarrowShell(st: st);
    return Scaffold(
      backgroundColor: c.bgApp,
      body: Stack(children: [
        Row(children: [
          const _Rail(),
          _VLine(c.border),
          const SizedBox(width: listWidth, child: _ListColumn()),
          _VLine(c.border),
          Expanded(child: _Content(st: st)),
        ]),
        const Positioned(top: 60, right: 16, child: MessageToast()),
      ]),
    );
  }
}

// ---- narrow (phone) layout: one page at a time + bottom navigation ---------------------------

class _NarrowShell extends ConsumerWidget {
  const _NarrowShell({required this.st});
  final AppState st;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    return Scaffold(
      // The status-bar inset takes the colour of the page below it (list pages use the sidebar tone).
      backgroundColor: st.section == Section.transfers ? c.bgApp : c.bgSidebar,
      body: Stack(children: [
        SafeArea(
          bottom: false,
          child: switch (st.section) {
            Section.transfers => const TransfersView(),
            _ => const _ListColumn(),
          },
        ),
        const Positioned(top: 8, left: 12, right: 12, child: SafeArea(child: MessageToast())),
      ]),
      bottomNavigationBar: const _BottomNav(),
    );
  }
}

/// Pushed detail page (chat / device / setting) on narrow screens.
class DetailPage extends StatelessWidget {
  const DetailPage({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: context.c.bgApp, body: SafeArea(child: child));
}

class _BottomNav extends ConsumerWidget {
  const _BottomNav();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    final store = ref.read(storeProvider.notifier);
    final active = st.transfers.where((t) => t.active).length;
    final updateDot = ref.watch(updateProvider.select((u) => u.badge));
    Widget item(Section s, IconData icon, String label, {int badge = 0, bool dot = false}) {
      final sel = st.section == s;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => store.setSection(s),
          child: SizedBox(
            height: 52,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Stack(clipBehavior: Clip.none, children: [
                Icon(icon, size: 20, color: sel ? c.actionText : c.text2),
                if (badge > 0)
                  Positioned(
                    right: -8,
                    top: -4,
                    child: Container(
                      height: 14,
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(color: c.action, borderRadius: BorderRadius.circular(7)),
                      alignment: Alignment.center,
                      child: Text(badge > 99 ? '99+' : '$badge', style: Type.badge.copyWith(color: c.actionFg, fontSize: 10, height: 1)),
                    ),
                  ),
                if (dot)
                  Positioned(
                    right: -4,
                    top: -2,
                    child: Container(width: 8, height: 8, decoration: BoxDecoration(color: c.action, shape: BoxShape.circle, border: Border.all(color: c.bgSidebar, width: 1.5))),
                  ),
              ]),
              const SizedBox(height: 3),
              Text(label, style: Type.badge.copyWith(color: sel ? c.actionText : c.text2, fontWeight: sel ? FontWeight.w600 : FontWeight.w500)),
            ]),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(color: c.bgSidebar, border: Border(top: BorderSide(color: c.border))),
      child: SafeArea(
        top: false,
        child: Row(children: [
          item(Section.chats, LucideIcons.messageSquare, '会话', badge: st.totalUnread),
          item(Section.devices, LucideIcons.laptop, '设备'),
          item(Section.transfers, LucideIcons.arrowLeftRight, '传输', badge: active),
          item(Section.settings, LucideIcons.settings, '设置', dot: updateDot),
        ]),
      ),
    );
  }
}

class _VLine extends StatelessWidget {
  const _VLine(this.color);
  final Color color;
  @override
  Widget build(BuildContext context) => Container(width: 1, color: color);
}

class _Content extends ConsumerWidget {
  const _Content({required this.st});
  final AppState st;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guest = ref.watch(isGuestProvider);
    final c = context.c;
    return switch (st.section) {
      Section.chats when st.showingHome && st.selectedPeer == null => const GuestWelcome(),
      Section.chats when guest => const Column(children: [
        PageHeader(title: '设备会话'),
        Expanded(child: GuestEmpty(icon: LucideIcons.messageSquare,
          title: '还没有会话', message: '登录后，选择设备开始发送消息和文件。')),
      ]),
      Section.chats => st.selectedPeer == null || st.device(st.selectedPeer!) == null
          ? Column(children: [
              const PageHeader(title: '设备会话'),
              Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.messagesSquare, size: 40, color: c.borderStrong),
                const SizedBox(height: 12),
                Text('选择一台设备开始会话', style: Type.body.copyWith(color: c.text3)),
                const SizedBox(height: 8),
                Text('从左侧会话列表选择设备，发送消息或文件。', style: Type.caption.copyWith(color: c.text3)),
              ]))),
            ])
          : ChatView(key: ValueKey(st.selectedPeer), peerId: st.selectedPeer!),
      Section.devices => DevicesView(deviceId: ref.watch(_devicePick) ?? st.self?.id ?? (guest ? 'local' : null)),
      Section.transfers => const TransfersView(),
      Section.settings => const SettingsView(),
    };
  }
}

class _DevicePick extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final _devicePick = NotifierProvider<_DevicePick, String?>(_DevicePick.new);

// ---- column 1: icon rail ---------------------------------------------------------------------

class _Rail extends ConsumerWidget {
  const _Rail();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    final store = ref.read(storeProvider.notifier);
    final activeTransfers = st.transfers.where((t) => t.active).length;
    Widget nav(Section s, IconData icon, String tip, {int badge = 0}) => _RailButton(
          icon: icon,
          tooltip: tip,
          selected: st.section == s && !(s == Section.chats && st.showingHome && st.selectedPeer == null),
          badge: badge,
          onTap: () => store.setSection(s),
        );
    return Container(
      width: railWidth,
      color: c.bgSidebar,
      child: Column(children: [
        // macOS: leave room for the traffic lights (cc-switch: h-11 drag zone). Windows/Linux have nothing
        // in the top-left corner (their buttons sit top-right): use the same gap as the logo's side margin,
        // (72 - 28) / 2 = 22px, so it sits evenly in the corner. A browser has no traffic lights either.
        DragArea(child: SizedBox(height: (hasCustomWindowControls || debugShowWindowControls || kIsWeb) ? (railWidth - 28) / 2 : 44, width: railWidth)),
        BrandHomeButton(onPressed: store.goHome),
        const SizedBox(height: 18),
        nav(Section.chats, LucideIcons.messageSquare, st.totalUnread > 0 ? '设备会话（${st.totalUnread} 条未读）' : '设备会话', badge: st.totalUnread),
        const SizedBox(height: 4),
        nav(Section.devices, LucideIcons.laptop, '设备管理'),
        const SizedBox(height: 4),
        nav(Section.transfers, LucideIcons.arrowLeftRight, '传输中心', badge: activeTransfers),
        const Spacer(),
        if (ref.watch(updateProvider.select((u) => u.badge))) ...[
          _RailButton(
            icon: LucideIcons.circleArrowUp,
            accent: true,
            selected: false,
            tooltip: '发现新版本 ${ref.watch(updateProvider.select((u) => u.latest?.version))}，点击查看并更新',
            onTap: () => showUpdateDialog(context),
          ),
          const SizedBox(height: 6),
        ],
        _LinkDot(state: st.link, guest: ref.watch(isGuestProvider)),
        const SizedBox(height: 8),
        nav(Section.settings, LucideIcons.settings, '设置'),
        const SizedBox(height: 14),
      ]),
    );
  }
}

class _RailButton extends StatefulWidget {
  const _RailButton({required this.icon, required this.tooltip, required this.selected, required this.onTap, this.badge = 0, this.accent = false});
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final int badge;
  final bool accent; // highlighted call-to-action (e.g. an update is available)
  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 48,
            height: 32,
            decoration: BoxDecoration(
              color: widget.selected ? c.bgSelected : (_hover ? c.bgSubtle : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              Icon(widget.icon, size: 18, color: widget.accent ? c.action : (widget.selected ? c.text1 : c.text2)),
              if (widget.badge > 0)
                Positioned(
                  right: 6,
                  top: -2,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 14),
                    height: 14,
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: c.action, borderRadius: BorderRadius.circular(7)),
                    child: Text(widget.badge > 99 ? '99+' : '${widget.badge}', style: Type.badge.copyWith(color: c.actionFg, fontSize: 10, height: 1)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _LinkDot extends StatelessWidget {
  const _LinkDot({required this.state, this.guest = false});
  final LinkState state;
  final bool guest;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (color, tip) = guest
        ? (c.controlOff, '未登录')
        : switch (state) {
      LinkState.connected => (c.success, '已连接服务器'),
      LinkState.connecting || LinkState.reconnecting => (c.warning, '正在连接服务器…'),
      LinkState.closed => (c.controlOff, '未连接'),
    };
    return Tooltip(message: tip, child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)));
  }
}

// ---- column 2: list panel --------------------------------------------------------------------

class _ListColumn extends ConsumerWidget {
  const _ListColumn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    final store = ref.read(storeProvider.notifier);
    final guest = ref.watch(isGuestProvider);
    final local = guest ? ref.watch(guestDeviceProvider).value : null;
    return Container(
      color: c.bgSidebar,
      child: Column(children: [
        const SizedBox(height: 14),
        if (st.section == Section.chats || st.section == Section.devices)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(children: [
              Expanded(
                child: LTextField(
                  hint: '搜索设备',
                  onChanged: store.setSearch,
                  fillColor: c.bgSubtle,
                  prefix: Icon(LucideIcons.search, size: 14, color: c.text3),
                ),
              ),
              const SizedBox(width: 6),
              LIconButton(icon: LucideIcons.refreshCw, tooltip: guest ? '登录后可刷新' : '刷新设备', size: 32, onPressed: guest ? null : store.refreshAll),
            ]),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(st.section == Section.transfers ? '传输中心' : '设置', style: Type.title.copyWith(color: c.text1)),
            ),
          ),
        Expanded(child: switch (st.section) {
          Section.chats when guest => const GuestEmpty(
              icon: LucideIcons.messagesSquare, title: '还没有会话', message: '登录后，你的其他设备会出现在这里，\n可直接发送消息和文件。', compact: true),
          Section.chats => _PeerList(devices: _filter(st.peers, st.search), forChat: true),
          Section.devices when guest => _PeerList(devices: [?local], forChat: false),
          Section.devices => _PeerList(devices: _filter(st.devices, st.search), forChat: false),
          Section.transfers => const _FilterList(),
          Section.settings => const _SettingsList(),
        }),
      ]),
    );
  }

  List<Device> _filter(List<Device> l, String q) =>
      q.trim().isEmpty ? l : l.where((d) => d.name.toLowerCase().contains(q.trim().toLowerCase())).toList();
}

class _PeerList extends ConsumerWidget {
  const _PeerList({required this.devices, required this.forChat});
  final List<Device> devices;
  final bool forChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    final store = ref.read(storeProvider.notifier);
    final picked = ref.watch(_devicePick) ?? st.self?.id;

    DateTime? lastAt(Device d) => st.messages[d.id]?.lastOrNull?.createdAt;
    final sorted = [...devices]..sort((a, b) {
        if (a.current != b.current) return a.current ? -1 : 1;
        final la = lastAt(a), lb = lastAt(b);
        if (la != null && lb != null) return lb.compareTo(la);
        if (la != null || lb != null) return la != null ? -1 : 1;
        final oa = st.isOnline(a.id) ? 0 : 1, ob = st.isOnline(b.id) ? 0 : 1;
        return oa.compareTo(ob);
      });

    if (sorted.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(forChat ? '账号下还没有其他设备。\n在另一台设备上登录同一账号后会出现在这里。' : '没有匹配的设备',
            textAlign: TextAlign.center, style: Type.caption.copyWith(color: c.text3)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: sorted.length,
      findChildIndexCallback: (key) {
        final index = sorted.indexWhere((d) => ValueKey('${forChat ? 'chat' : 'device'}-${d.id}') == key);
        return index < 0 ? null : index;
      },
      itemBuilder: (_, i) {
        final d = sorted[i];
        final guest = ref.watch(isGuestProvider);
        final online = (d.current && !guest) || st.isOnline(d.id);
        final last = st.messages[d.id]?.lastOrNull;
        final unread = forChat ? (st.unread[d.id] ?? 0) : 0;
        final selected = forChat ? st.selectedPeer == d.id : picked == d.id;
        final sub = forChat
            ? (last == null ? (online ? '在线' : '离线') : '${last.mine ? '你：' : ''}${last.type == 'clipboard' ? '[剪贴板] ' : ''}${last.content.replaceAll('\n', ' ')}')
            : '${deviceTypeLabel(d.type)} · ${d.current ? (guest ? '本机 · 未登录' : '本机') : online ? '在线' : '离线'}';
        return Padding(
          key: ValueKey('${forChat ? 'chat' : 'device'}-${d.id}'),
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: HoverRow(
            selected: selected,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            onTap: () {
              if (forChat) {
                store.selectPeer(d.id);
              } else {
                ref.read(_devicePick.notifier).set(d.id);
              }
              if (isNarrow(context)) {
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => DetailPage(child: forChat ? ChatView(key: ValueKey(d.id), peerId: d.id) : DevicesView(deviceId: d.id))));
              }
            },
            child: Row(children: [
              DeviceGlyph(type: d.type, online: online),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(d.name,
                          style: Type.strong.copyWith(color: c.text1, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (forChat && last != null) Text(fmtListTime(last.createdAt), style: Type.caption.copyWith(color: c.text3)),
                  ]),
                  const SizedBox(height: 2),
                  Row(children: [
                    Expanded(
                      child: Text(sub,
                          style: Type.caption.copyWith(color: unread > 0 ? c.text2 : c.text3, fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.w400),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (forChat && unread > 0) ...[const SizedBox(width: 8), UnreadBadge(unread)],
                  ]),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _FilterList extends ConsumerWidget {
  const _FilterList();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final cur = ref.watch(transferFilterProvider);
    final ts = ref.watch(storeProvider).transfers;
    int count(TransferFilter f) => ts.where((t) => switch (f) {
          TransferFilter.all => true,
          TransferFilter.active => t.active,
          TransferFilter.done => t.status == 'COMPLETED',
          TransferFilter.failed => !t.active && t.status != 'COMPLETED',
        }).length;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
      for (final f in TransferFilter.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: HoverRow(
            selected: cur == f,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onTap: () => ref.read(transferFilterProvider.notifier).set(f),
            child: SizedBox(
              height: 28,
              child: Row(children: [
                Icon(f.icon, size: 16, color: c.text2),
                const SizedBox(width: 8),
                Expanded(child: Text(f.label, style: Type.body.copyWith(color: c.text1, fontWeight: cur == f ? FontWeight.w500 : FontWeight.w400))),
                Text('${count(f)}', style: Type.caption.copyWith(color: c.text3)),
              ]),
            ),
          ),
        ),
    ]);
  }
}

class _SettingsList extends ConsumerWidget {
  const _SettingsList();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final cur = ref.watch(settingsTabProvider);
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
      for (final t in SettingsTab.values.where((t) => !kIsWeb || (t != SettingsTab.transfer && t != SettingsTab.update)))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: HoverRow(
            selected: cur == t,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onTap: () {
              ref.read(settingsTabProvider.notifier).set(t);
              if (isNarrow(context)) {
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DetailPage(child: SettingsView())));
              }
            },
            child: SizedBox(
              height: 28,
              child: Row(children: [
                Icon(t.icon, size: 16, color: c.text2),
                const SizedBox(width: 8),
                Expanded(child: Text(t.label, style: Type.body.copyWith(color: c.text1, fontWeight: cur == t ? FontWeight.w500 : FontWeight.w400))),
                if (t == SettingsTab.update && ref.watch(updateProvider.select((u) => u.badge))) Container(width: 8, height: 8, decoration: BoxDecoration(color: c.action, shape: BoxShape.circle)),
              ]),
            ),
          ),
        ),
    ]);
  }
}
