import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/models.dart';
import '../../core/realtime.dart';
import '../../core/store.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';
import '../chat/chat_view.dart';
import '../devices/devices_view.dart';
import '../settings/settings_view.dart';
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
    return Scaffold(
      backgroundColor: c.bgApp,
      body: Row(children: [
        const _Rail(),
        _VLine(c.border),
        const SizedBox(width: listWidth, child: _ListColumn()),
        _VLine(c.border),
        Expanded(child: _Content(st: st)),
      ]),
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
    final c = context.c;
    return switch (st.section) {
      Section.chats => st.selectedPeer == null || st.device(st.selectedPeer!) == null
          ? Column(children: [
              const PageHeader(title: '连信'),
              Expanded(
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(LucideIcons.messagesSquare, size: 40, color: c.borderStrong),
                    const SizedBox(height: 12),
                    Text('选择一台设备开始传输', style: Type.body.copyWith(color: c.text3)),
                  ]),
                ),
              ),
            ])
          : ChatView(key: ValueKey(st.selectedPeer), peerId: st.selectedPeer!),
      Section.devices => DevicesView(deviceId: ref.watch(_devicePick) ?? st.self?.id),
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
          selected: st.section == s,
          badge: badge,
          onTap: () => store.setSection(s),
        );
    return Container(
      width: railWidth,
      color: c.bgSidebar,
      child: Column(children: [
        const SizedBox(height: 44), // room for the macOS traffic lights (cc-switch: h-11 drag zone)
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: c.action, borderRadius: BorderRadius.circular(7)),
          child: Icon(LucideIcons.link2, size: 16, color: c.actionFg),
        ),
        const SizedBox(height: 18),
        nav(Section.chats, LucideIcons.messageSquare, '设备会话'),
        const SizedBox(height: 4),
        nav(Section.devices, LucideIcons.laptop, '设备管理'),
        const SizedBox(height: 4),
        nav(Section.transfers, LucideIcons.arrowLeftRight, '传输中心', badge: activeTransfers),
        const Spacer(),
        _LinkDot(state: st.link),
        const SizedBox(height: 8),
        nav(Section.settings, LucideIcons.settings, '设置'),
        const SizedBox(height: 14),
      ]),
    );
  }
}

class _RailButton extends StatefulWidget {
  const _RailButton({required this.icon, required this.tooltip, required this.selected, required this.onTap, this.badge = 0});
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final int badge;
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
              Icon(widget.icon, size: 18, color: widget.selected ? c.text1 : c.text2),
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
                    child: Text('${widget.badge}', style: Type.badge.copyWith(color: c.actionFg, fontSize: 10, height: 1)),
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
  const _LinkDot({required this.state});
  final LinkState state;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (color, tip) = switch (state) {
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
              LIconButton(icon: LucideIcons.refreshCw, tooltip: '刷新设备', size: 32, onPressed: store.refreshAll),
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
          Section.chats => _PeerList(devices: _filter(st.peers, st.search), forChat: true),
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
      itemBuilder: (_, i) {
        final d = sorted[i];
        final online = d.current || st.isOnline(d.id);
        final last = st.messages[d.id]?.lastOrNull;
        final selected = forChat ? st.selectedPeer == d.id : picked == d.id;
        final sub = forChat
            ? (last == null ? (online ? '在线' : '离线') : '${last.mine ? '' : ''}${last.type == 'clipboard' ? '[剪贴板] ' : ''}${last.content.replaceAll('\n', ' ')}')
            : '${deviceTypeLabel(d.type)} · ${d.current ? '本机' : online ? '在线' : '离线'}';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: HoverRow(
            selected: selected,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            onTap: () => forChat ? store.selectPeer(d.id) : ref.read(_devicePick.notifier).set(d.id),
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
                  Text(sub, style: Type.caption.copyWith(color: c.text3), maxLines: 1, overflow: TextOverflow.ellipsis),
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
      for (final t in SettingsTab.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: HoverRow(
            selected: cur == t,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onTap: () => ref.read(settingsTabProvider.notifier).set(t),
            child: SizedBox(
              height: 28,
              child: Row(children: [
                Icon(t.icon, size: 16, color: c.text2),
                const SizedBox(width: 8),
                Expanded(child: Text(t.label, style: Type.body.copyWith(color: c.text1, fontWeight: cur == t ? FontWeight.w500 : FontWeight.w400))),
              ]),
            ),
          ),
        ),
    ]);
  }
}
