import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/store.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

String statusLabel(Transfer t) => switch (t.status) {
      'WAITING_ACCEPT' => '等待对方确认',
      'ACCEPTED' => '准备传输',
      'TRANSFERRING' => '传输中',
      'VERIFYING' => '校验中',
      'COMPLETED' => '已完成',
      'REJECTED' => '已拒绝',
      'CANCELLED' => '已取消',
      'EXPIRED' => '已过期',
      _ => t.error.isEmpty ? '传输失败' : '传输失败',
    };

/// A file task: icon tile, name/size line, progress, and the actions valid for the current state.
class TransferCard extends ConsumerWidget {
  const TransferCard({super.key, required this.task, this.showPeer = false});
  final Transfer task;
  final bool showPeer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final self = ref.watch(sessionProvider).deviceId;
    final store = ref.read(storeProvider.notifier);
    final st = ref.watch(storeProvider);
    final incoming = task.receiver == self;
    final peer = st.device(incoming ? task.sender : task.receiver)?.name ?? '未知设备';
    final ok = task.status == 'COMPLETED';
    final bad = const {'FAILED', 'REJECTED', 'CANCELLED', 'EXPIRED'}.contains(task.status);
    final color = ok ? c.successText : bad ? c.dangerText : c.directText;
    final progress = task.size == 0 ? 0.0 : (task.bytes / task.size).clamp(0.0, 1.0);

    final actions = <Widget>[];
    // Two compact icons instead of wide buttons: open the file / show it in the file manager.
    // Files I sent: available any time (the source file); files I received: once complete.
    final hasFile = store.canOpenFiles && store.fileOf(task) != null && (!incoming || ok);
    if (hasFile) {
      actions.add(LIconButton(icon: LucideIcons.externalLink, tooltip: '打开文件', size: 28, onPressed: () => store.openFile(task)));
      actions.add(LIconButton(icon: LucideIcons.folderOpen, tooltip: '在文件夹中显示', size: 28, onPressed: () => store.revealFile(task)));
    }
    if (task.status == 'WAITING_ACCEPT' && incoming) {
      actions.add(LButton(label: '接收', compact: true, variant: BtnVariant.solid, onPressed: () => store.accept(task)));
      actions.add(LButton(label: '拒绝', compact: true, onPressed: () => store.reject(task)));
    } else if (task.active) {
      actions.add(LButton(label: '取消', compact: true, onPressed: () => store.cancel(task)));
    } else {
      if (store.canRetry(task)) {
        actions.add(LButton(label: '重试', compact: true, icon: LucideIcons.rotateCw, onPressed: () => store.retryTransfer(task)));
      }
      actions.add(LIconButton(icon: LucideIcons.x, tooltip: '移除记录（不删除已保存的文件）', size: 28, iconSize: 14, onPressed: () => store.removeTransferRecord(task)));
    }
    final elapsed = task.startedAt == null ? null : (task.finishedAt ?? DateTime.now()).difference(task.startedAt!);
    final detail = [
      if (task.status == 'TRANSFERRING' && task.speed > 0) '${fmtBytes(task.speed.round())}/s',
      if (elapsed != null && elapsed.inSeconds > 0) '耗时 ${fmtDuration(elapsed)}',
    ].join(' · ');

    return PanelCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: c.bgSubtle, borderRadius: BorderRadius.circular(Radii.panel), border: Border.all(color: c.border)),
          child: Icon(LucideIcons.file, size: 20, color: c.text2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(task.fileName, style: Type.strong.copyWith(color: c.text1), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Row(children: [
              Icon(incoming ? LucideIcons.arrowDownToLine : LucideIcons.arrowUpFromLine, size: 12, color: c.text3),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '${fmtBytes(task.size)}${showPeer ? ' · ${incoming ? '来自' : '发往'} $peer' : ''}',
                  style: Type.caption.copyWith(color: c.text2),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                task.status == 'TRANSFERRING' ? '${statusLabel(task)} ${(progress * 100).floor()}%' : statusLabel(task),
                style: Type.caption.copyWith(color: color),
              ),
              if (task.mode == 'lan' && (task.active || ok)) ...[
                const SizedBox(width: 8),
                const LBadge('局域网直连'),
              ],
              if (detail.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(detail, style: Type.caption.copyWith(color: c.text3)),
              ],
            ]),
            if (task.status == 'TRANSFERRING' || task.status == 'VERIFYING') ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: task.status == 'VERIFYING' ? null : progress,
                  minHeight: 3,
                  backgroundColor: c.bgSubtle,
                  color: c.action,
                ),
              ),
            ],
          ]),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(width: 12),
          for (final a in actions) Padding(padding: EdgeInsets.only(left: a is LIconButton ? 2 : 6), child: a),
        ],
      ]),
    );
  }
}
