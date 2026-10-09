import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/store.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

class DevicesView extends ConsumerWidget {
  const DevicesView({super.key, required this.deviceId});
  final String? deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    final d = deviceId == null ? null : st.device(deviceId!);
    if (d == null) {
      return Column(children: [
        const PageHeader(title: '设备管理'),
        Expanded(child: Center(child: Text('选择左侧设备查看详情', style: Type.body.copyWith(color: c.text3)))),
      ]);
    }
    final online = d.current || st.isOnline(d.id);
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            SizedBox(width: 96, child: Text(k, style: Type.body.copyWith(color: c.text3))),
            Expanded(child: SelectableText(v.isEmpty ? '—' : v, style: Type.body.copyWith(color: c.text1))),
          ]),
        );
    return Column(children: [
      PageHeader(title: d.name, subtitle: d.current ? '本机' : null, actions: [
        LButton(label: '重命名', icon: LucideIcons.pencil, compact: true, onPressed: () => _rename(context, ref, d)),
        if (!d.current)
          LButton(label: '移除设备', icon: LucideIcons.trash2, compact: true, onPressed: () => _remove(context, ref, d)),
      ]),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          PanelCard(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              DeviceGlyph(type: d.type, size: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, style: Type.section.copyWith(color: c.text1)),
                  const SizedBox(height: 4),
                  Row(children: [
                    LBadge(online ? '在线' : '离线', bg: online ? c.successSoft : c.bgSubtle, fg: online ? c.successText : c.text2),
                    const SizedBox(width: 6),
                    LBadge(deviceTypeLabel(d.type), outline: true),
                  ]),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          PanelCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Column(children: [
              row('设备 ID', d.id),
              Divider(height: 1, color: c.border),
              row('系统版本', d.osVersion),
              Divider(height: 1, color: c.border),
              row('客户端版本', d.appVersion),
              Divider(height: 1, color: c.border),
              row('最近在线', online ? '现在' : fmtLastSeen(d.lastSeenAt)),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Device d) async {
    final ctl = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => LDialog(
        title: '重命名设备',
        body: LTextField(controller: ctl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        confirm: '保存',
        onConfirm: () => Navigator.pop(ctx, ctl.text),
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == d.name) return;
    try {
      await ref.read(storeProvider.notifier).renameDevice(d.id, name.trim());
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, Device d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => LDialog(
        title: '移除设备',
        body: Text('移除「${d.name}」后，它的登录凭证立即失效，需要重新登录才能再次使用。', style: Type.body.copyWith(color: ctx.c.text2)),
        confirm: '移除',
        danger: true,
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (ok == true) await ref.read(storeProvider.notifier).removeDevice(d.id);
  }
}
