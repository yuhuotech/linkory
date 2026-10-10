import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/models.dart';
import '../../core/store.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

/// Width reserved for the peer's avatar column (28px avatar + 8px gap).
const avatarSlot = 36.0;

/// One chat message. Consecutive messages from the same side form a group: the first carries the
/// avatar and full corners, the following ones sit closer and square off the corners that touch.
class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({super.key, required this.msg, this.first = true, this.last = true, this.peer, this.maxWidth = 560, this.topSpacing});
  final ChatMessage msg;
  final bool first, last;
  final double? topSpacing;
  final Device? peer;
  final double maxWidth;
  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble> {
  bool _hover = false, _expanded = false;

  bool get _long => widget.msg.content.split('\n').length > 4 || widget.msg.content.length > 240;

  BorderRadius _radius(bool mine) {
    const r = Radius.circular(Radii.panel), s = Radius.circular(4);
    final f = widget.first, l = widget.last;
    return mine
        ? BorderRadius.only(topLeft: r, bottomLeft: r, topRight: f ? r : s, bottomRight: l ? r : s)
        : BorderRadius.only(topRight: r, bottomRight: r, topLeft: f ? r : s, bottomLeft: l ? r : s);
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
    final c = context.c;
    final mine = msg.mine;
    final clip = msg.type == 'clipboard';
    final collapsed = _long && !_expanded;

    final text = clip
        ? Text(msg.content,
            maxLines: collapsed ? 4 : null,
            overflow: collapsed ? TextOverflow.fade : TextOverflow.clip,
            style: Type.body.copyWith(color: c.text1, fontSize: 13, height: 1.5, fontFamilyFallback: Type.monoFallback))
        : SelectableText(msg.content, style: Type.body.copyWith(color: c.text1, fontSize: 14, height: 1.5));

    Widget inner = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (clip)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(LucideIcons.clipboard, size: 12, color: mine ? c.actionText : c.text3),
              const SizedBox(width: 4),
              Text('剪贴板', style: Type.badge.copyWith(color: mine ? c.actionText : c.text3)),
            ]),
          ),
        text,
        if (clip) ...[
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _TextAction(icon: LucideIcons.copy, label: '复制', onTap: () => copyText(context, msg.content)),
            if (_long) ...[
              const SizedBox(width: 12),
              _TextAction(
                  icon: _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  label: _expanded ? '收起' : '展开',
                  onTap: () => setState(() => _expanded = !_expanded)),
            ],
          ]),
        ],
      ]),
    );
    if (clip) {
      // Left accent bar marks "this is clipboard content".
      inner = IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 3, color: mine ? c.action : c.borderStrong),
          Flexible(child: inner),
        ]),
      );
    }
    final failed = msg.status == MsgStatus.failed;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      decoration: BoxDecoration(
        color: mine ? c.actionSoft : c.bgSubtle,
        borderRadius: _radius(mine),
        border: failed ? Border.all(color: c.danger.withValues(alpha: .6)) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: inner,
    );

    // Only the last message of a group shows its delivery state; sending/failed always show.
    final status = switch (msg.status) {
      MsgStatus.sending => ('发送中', c.text3),
      MsgStatus.serverReceived => ('已发送', c.text3),
      MsgStatus.delivered => ('已送达', c.successText),
      MsgStatus.failed => ('发送失败', c.dangerText),
    };
    final showStatus = mine && (widget.last || msg.status == MsgStatus.sending || failed);

    // Hover tools (copy / delete the local record) with the exact time; hidden otherwise.
    final tools = Opacity(
      opacity: _hover ? 1 : 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(fmtClock(msg.createdAt), style: Type.badge.copyWith(color: c.text3)),
          const SizedBox(width: 4),
          if (!clip) LIconButton(icon: LucideIcons.copy, tooltip: '复制', size: 24, iconSize: 14, onPressed: () => copyText(context, msg.content)),
          LIconButton(
              icon: LucideIcons.trash2,
              tooltip: '删除本地记录',
              size: 24,
              iconSize: 14,
              onPressed: () => ref.read(storeProvider.notifier).deleteMessage(msg)),
        ]),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(top: widget.topSpacing ?? (widget.first ? 10 : 2)),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Row(
          mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!mine) PeerAvatar(peer: widget.peer, show: widget.first),
            if (mine) ...[
              tools,
              if (failed) LIconButton(icon: LucideIcons.rotateCw, tooltip: '重试', onPressed: () => ref.read(storeProvider.notifier).retry(msg)),
              if (showStatus)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 2),
                  child: Text(status.$1, style: Type.badge.copyWith(color: status.$2)),
                ),
            ],
            Flexible(child: bubble),
            if (!mine) tools,
          ],
        ),
      ),
    );
  }
}

/// The peer's avatar on the first row of a group; an equally wide gap on the following rows.
class PeerAvatar extends StatelessWidget {
  const PeerAvatar({super.key, required this.peer, required this.show});
  final Device? peer;
  final bool show;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: avatarSlot,
        child: show && peer != null ? Align(alignment: Alignment.bottomLeft, child: DeviceGlyph(type: peer!.type, size: 28)) : null,
      );
}

class _TextAction extends StatefulWidget {
  const _TextAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final col = _hover ? c.actionText : c.text3;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(widget.icon, size: 12, color: col),
          const SizedBox(width: 4),
          Text(widget.label, style: Type.badge.copyWith(color: col)),
        ]),
      ),
    );
  }
}
