import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/store.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

/// Unread count pill (orange, 99+ cap) used on conversation rows.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge(this.count, {super.key});
  final int count;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.action, borderRadius: BorderRadius.circular(9)),
      child: Text(count > 99 ? '99+' : '$count', style: Type.badge.copyWith(color: c.actionFg, height: 1)),
    );
  }
}

/// Banner for a message that arrives while the window is in front but another conversation is open
/// (no system notification in that case, like WeChat). Click to open the conversation.
class MessageToast extends ConsumerWidget {
  const MessageToast({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(toastProvider);
    final c = context.c;
    final peer = t == null ? null : ref.watch(storeProvider.select((s) => s.device(t.peerId)));
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0.08, 0), end: Offset.zero).animate(a), child: child),
      ),
      child: t == null
          ? const SizedBox.shrink(key: ValueKey('none'))
          : MouseRegion(
              key: ValueKey(t.id),
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => ref.read(storeProvider.notifier).openConversation(t.peerId),
                child: Container(
                  width: 320,
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  decoration: BoxDecoration(
                    color: c.bgCard,
                    borderRadius: BorderRadius.circular(Radii.panel),
                    border: Border.all(color: c.border),
                    boxShadow: c.shadowMd,
                  ),
                  child: Row(children: [
                    DeviceGlyph(type: peer?.type ?? 'windows', size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Row(children: [
                          Expanded(child: Text(t.title, style: Type.strong.copyWith(color: c.text1), overflow: TextOverflow.ellipsis)),
                          if (t.count > 1) UnreadBadge(t.count),
                        ]),
                        const SizedBox(height: 2),
                        Text(t.body, style: Type.caption.copyWith(color: c.text2), maxLines: 2, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    LIconButton(icon: LucideIcons.x, tooltip: '忽略', size: 24, iconSize: 14, onPressed: ref.read(toastProvider.notifier).dismiss),
                  ]),
                ),
              ),
            ),
    );
  }
}
