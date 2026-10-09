import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/tokens.dart';
import 'widgets.dart';

/// Navigator of the root app, so window-level events (the close button) can open dialogs.
final rootNavigatorKey = GlobalKey<NavigatorState>();

class CloseChoice {
  const CloseChoice({required this.toTray, required this.remember});
  final bool toTray, remember;
}

/// "Quit or keep running in the tray?" — asked on the first close on Windows/Linux.
/// Returns null when the user cancels (the window stays open).
Future<CloseChoice?> showCloseDialog(BuildContext context, {required bool trayAvailable}) =>
    showDialog<CloseChoice>(context: context, builder: (_) => _CloseDialog(trayAvailable: trayAvailable));

class _CloseDialog extends StatefulWidget {
  const _CloseDialog({required this.trayAvailable});
  final bool trayAvailable;
  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  late bool _toTray = widget.trayAvailable; // hide to tray is the default choice
  bool _remember = true;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LDialog(
      title: '关闭连信',
      confirm: '确定',
      onConfirm: () => Navigator.pop(context, CloseChoice(toTray: _toTray, remember: _remember)),
      body: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Option(
          selected: _toTray,
          enabled: widget.trayAvailable,
          icon: LucideIcons.panelBottomClose,
          title: '隐藏到托盘',
          subtitle: widget.trayAvailable ? '后台继续运行，保持连接并接收消息和文件' : '当前桌面没有托盘支持（GNOME 需启用 AppIndicator 扩展）',
          onTap: () => setState(() => _toTray = true),
        ),
        const SizedBox(height: 8),
        _Option(
          selected: !_toTray,
          icon: LucideIcons.power,
          title: '退出应用',
          subtitle: '完全关闭，不再接收消息和文件',
          onTap: () => setState(() => _toTray = false),
        ),
        const SizedBox(height: 14),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _remember = !_remember),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: _remember ? c.action : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: _remember ? c.action : c.borderStrong),
                ),
                child: _remember ? Icon(LucideIcons.check, size: 12, color: c.actionFg) : null,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('记住我的选择（可在 设置 → 通用 中修改）', style: Type.caption.copyWith(color: c.text2))),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.selected, required this.icon, required this.title, required this.subtitle, required this.onTap, this.enabled = true});
  final bool selected, enabled;
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? c.actionSoft : c.bgCard,
              borderRadius: BorderRadius.circular(Radii.panel),
              border: Border.all(color: selected ? c.action : c.border, width: selected ? 1.5 : 1),
            ),
            child: Row(children: [
              Icon(icon, size: 18, color: selected ? c.actionText : c.text2),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Type.strong.copyWith(color: c.text1)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Type.caption.copyWith(color: c.text3)),
                ]),
              ),
              const SizedBox(width: 8),
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: selected ? c.action : c.borderStrong, width: selected ? 5 : 1.5),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
