import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/store.dart';
import '../../shared/file_kind.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';
import '../chat/image_viewer.dart';

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
    final peer =
        st.device(incoming ? task.sender : task.receiver)?.name ?? '未知设备';
    final ok = task.status == 'COMPLETED';
    final bad = const {
      'FAILED',
      'REJECTED',
      'CANCELLED',
      'EXPIRED',
    }.contains(task.status);
    final color = ok
        ? c.successText
        : bad
        ? c.dangerText
        : c.directText;
    final progress = task.size == 0
        ? 0.0
        : (task.bytes / task.size).clamp(0.0, 1.0);

    final actions = <Widget>[];
    // Two compact icons instead of wide buttons: open the file / show it in the file manager.
    // Files I sent: available any time (the source file); files I received: once complete.
    final hasFile =
        store.canOpenFiles && store.fileOf(task) != null && (!incoming || ok);
    if (hasFile) {
      actions.add(
        LIconButton(
          icon: LucideIcons.externalLink,
          tooltip: '打开文件',
          size: 28,
          onPressed: () => store.openFile(task),
        ),
      );
      actions.add(
        LIconButton(
          icon: LucideIcons.folderOpen,
          tooltip: '在文件夹中显示',
          size: 28,
          onPressed: () => store.revealFile(task),
        ),
      );
    }
    if (task.status == 'WAITING_ACCEPT' && incoming) {
      actions.add(
        LButton(
          label: '接收',
          compact: true,
          variant: BtnVariant.solid,
          onPressed: () => store.accept(task),
        ),
      );
      actions.add(
        LButton(
          label: '拒绝',
          compact: true,
          onPressed: () => store.reject(task),
        ),
      );
    } else if (task.active) {
      actions.add(
        LButton(
          label: '取消',
          compact: true,
          onPressed: () => store.cancel(task),
        ),
      );
    } else {
      if (store.canRetry(task)) {
        actions.add(
          LButton(
            label: '重试',
            compact: true,
            icon: LucideIcons.rotateCw,
            onPressed: () => store.retryTransfer(task),
          ),
        );
      }
      actions.add(
        LIconButton(
          icon: LucideIcons.x,
          tooltip: '移除记录（不删除已保存的文件）',
          size: 28,
          iconSize: 14,
          onPressed: () => store.removeTransferRecord(task),
        ),
      );
    }
    final elapsed = task.startedAt == null
        ? null
        : (task.finishedAt ?? DateTime.now()).difference(task.startedAt!);
    final detail = [
      if (task.status == 'TRANSFERRING' && task.speed > 0)
        '${fmtBytes(task.speed.round())}/s',
      if (elapsed != null && elapsed.inSeconds > 0)
        '耗时 ${fmtDuration(elapsed)}',
    ].join(' · ');

    final kind = fileKindOf(task.fileName);
    final (tileBg, tileFg) = kind.tones(c);
    final path = store.fileOf(task);
    // Images get a preview above the details once the file is on disk (sent: the source file;
    // received: when complete). Clicking it opens the full-size viewer.
    final previewPath =
        kind == FileKind.image && path != null && (!incoming || ok)
        ? path
        : null;
    final tile = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: tileBg,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: c.border),
      ),
      child: Icon(kind.icon, size: 22, color: tileFg),
    );

    Widget actionRow() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in actions)
          Padding(
            padding: EdgeInsets.only(left: a is LIconButton ? 2 : 6),
            child: a,
          ),
      ],
    );
    return PanelCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: LayoutBuilder(
        builder: (context, box) {
          // Narrow cards (phones) put the actions on their own line instead of squeezing the text.
          final stacked = box.maxWidth < 300 && actions.length > 1;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (previewPath != null)
                ImagePreview(
                  path: previewPath,
                  onTap: () => showImageViewer(
                    context,
                    path: previewPath,
                    name: task.fileName,
                    onOpen: store.canOpenFiles ? () => store.openFile(task) : null,
                    onReveal: store.canOpenFiles ? () => store.revealFile(task) : null,
                  ),
                ),
              Row(
                children: [
                  tile,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.fileName,
                          style: Type.strong.copyWith(color: c.text1),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 8,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  incoming
                                      ? LucideIcons.arrowDownToLine
                                      : LucideIcons.arrowUpFromLine,
                                  size: 12,
                                  color: c.text3,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '${fmtBytes(task.size)}${showPeer ? ' · ${incoming ? '来自' : '发往'} $peer' : ''}',
                                    style: Type.caption.copyWith(
                                      color: c.text2,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              task.status == 'TRANSFERRING'
                                  ? '${statusLabel(task)} ${(progress * 100).floor()}%'
                                  : statusLabel(task),
                              style: Type.caption.copyWith(color: color),
                            ),
                            if (task.mode == 'lan' && (task.active || ok))
                              const LBadge('局域网直连'),
                            if (detail.isNotEmpty)
                              Text(
                                detail,
                                style: Type.caption.copyWith(color: c.text3),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (actions.isNotEmpty && !stacked) ...[
                    const SizedBox(width: 8),
                    actionRow(),
                  ],
                ],
              ),
              if (actions.isNotEmpty && stacked) ...[
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: actionRow()),
              ],
              if (task.status == 'TRANSFERRING' ||
                  task.status == 'VERIFYING') ...[
                const SizedBox(height: 10),
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
            ],
          );
        },
      ),
    );
  }
}

/// Inline preview of an image file: cropped to 16:10, decoded at preview size only, lazy (the list only
/// builds what is on screen). Renders nothing if the file is gone or not a decodable image.
class ImagePreview extends StatefulWidget {
  const ImagePreview({super.key, required this.path, required this.onTap});
  final String path;
  final VoidCallback onTap;
  @override
  State<ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<ImagePreview> {
  bool? _exists; // checked once off the build path (no synchronous disk access while scrolling)
  bool _failed = false, _hover = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void didUpdateWidget(ImagePreview old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _exists = null;
      _failed = false;
      _probe();
    }
  }

  Future<void> _probe() async {
    final ok = await File(widget.path).exists();
    if (mounted) setState(() => _exists = ok);
  }

  @override
  Widget build(BuildContext context) {
    if (_exists != true || _failed) return const SizedBox.shrink();
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.control),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: c.bgSubtle),
                  Image.file(
                    File(widget.path),
                    fit: BoxFit.cover,
                    cacheWidth: 640, // ≈ 2× the card width: sharp on HiDPI, tiny in memory
                    gaplessPlayback: true,
                  // Large photos decode off the UI thread; fade in when ready instead of popping.
                  frameBuilder: (_, child, frame, sync) => sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 160), child: child),
                    errorBuilder: (_, _, _) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) setState(() => _failed = true);
                      });
                      return const SizedBox.shrink();
                    },
                  ),
                  AnimatedOpacity(
                    opacity: _hover ? 1 : 0,
                    duration: const Duration(milliseconds: 100),
                    child: ColoredBox(
                      color: Colors.black26,
                      child: Center(
                        child: Icon(
                          LucideIcons.maximize2,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
