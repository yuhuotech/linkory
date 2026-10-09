import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../theme/tokens.dart';

/// Full-window image preview: pinch / scroll to zoom, drag to pan, double-click to toggle 2.5×, Esc or
/// a click on the empty background to close. The picture is decoded at most [maxDecode] px on its long
/// side (a 48-megapixel photo must not cost 200 MB); "open" hands the untouched original to the system viewer.
Future<void> showImageViewer(
  BuildContext context, {
  required String path,
  required String name,
  VoidCallback? onOpen,
  VoidCallback? onReveal,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: '关闭图片预览',
  barrierColor: Colors.black.withValues(alpha: .88),
  transitionDuration: const Duration(milliseconds: 120),
  transitionBuilder: (_, a, _, child) =>
      FadeTransition(opacity: a, child: child),
  pageBuilder: (_, _, _) =>
      _ImageViewer(path: path, name: name, onOpen: onOpen, onReveal: onReveal),
);

const maxDecode = 2560;

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({
    required this.path,
    required this.name,
    this.onOpen,
    this.onReveal,
  });
  final String path, name;
  final VoidCallback? onOpen, onReveal;
  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  final _tc = TransformationController();
  Offset _lastDoubleTap = Offset.zero;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  bool get _zoomed => _tc.value.getMaxScaleOnAxis() > 1.05;

  void _toggleZoom() {
    if (_zoomed) {
      _tc.value = Matrix4.identity();
    } else {
      const s = 2.5;
      final p = _lastDoubleTap;
      _tc.value = Matrix4.identity()
        ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final close = Navigator.of(context).maybePop;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => close(),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (!_zoomed) close();
                  },
                  onDoubleTapDown: (d) => _lastDoubleTap = d.localPosition,
                  onDoubleTap: _toggleZoom,
                  child: InteractiveViewer(
                    transformationController: _tc,
                    minScale: 0.5,
                    maxScale: 8,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
                        child: Image.file(
                          File(widget.path),
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          // Decode no larger than needed for any realistic window.
                          cacheWidth: maxDecode,
                          errorBuilder: (_, _, _) => Text(
                            '无法显示这张图片',
                            style: Type.body.copyWith(color: Colors.white70),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: .6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.name,
                          style: Type.strong.copyWith(color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.onOpen != null)
                        _ViewerButton(
                          icon: LucideIcons.externalLink,
                          tooltip: '用系统程序打开原图',
                          onTap: widget.onOpen!,
                        ),
                      if (widget.onReveal != null)
                        _ViewerButton(
                          icon: LucideIcons.folderOpen,
                          tooltip: '在文件夹中显示',
                          onTap: widget.onReveal!,
                        ),
                      _ViewerButton(
                        icon: LucideIcons.x,
                        tooltip: '关闭（Esc）',
                        onTap: () => close(),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Text(
                      '滚轮缩放 · 拖动平移 · 双击放大 · Esc 关闭',
                      style: Type.caption.copyWith(color: Colors.white54),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewerButton extends StatefulWidget {
  const _ViewerButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  @override
  State<_ViewerButton> createState() => _ViewerButtonState();
}

class _ViewerButtonState extends State<_ViewerButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.tooltip,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.only(left: 6),
          decoration: BoxDecoration(
            color: _hover ? Colors.white24 : Colors.white12,
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: Icon(widget.icon, size: 16, color: Colors.white),
        ),
      ),
    ),
  );
}
