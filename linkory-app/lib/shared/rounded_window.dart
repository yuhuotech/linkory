import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/log.dart';
import '../theme/tokens.dart';

/// Rounded corners for the frameless Linux window (macOS does it natively; Windows 11 is asked to via
/// DWM in the runner). The runner makes the GTK window transparent when a compositor can blend it; this
/// widget then clips the app to a rounded rectangle and draws a hairline border. Without transparency
/// (no compositor) it renders the app unchanged, so the corners are simply square rather than broken.
/// Maximised and full-screen windows go back to square corners.
class RoundedWindow extends StatefulWidget {
  const RoundedWindow({super.key, required this.child, this.radius = 12});
  final Widget child;
  final double radius;

  @override
  State<RoundedWindow> createState() => _RoundedWindowState();
}

class _RoundedWindowState extends State<RoundedWindow> with WindowListener {
  static const _channel = MethodChannel('com.yuhuo.linkory/window');
  bool _transparent = false, _square = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _channel.invokeMethod<bool>('isTransparent').then((v) {
      if (mounted && v == true) {
        Log.info('window', 'transparent window: rounded corners on');
        setState(() => _transparent = true);
      }
    }).catchError((_) {});
    _refresh();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final sq = await windowManager.isMaximized() || await windowManager.isFullScreen();
    if (mounted && sq != _square) setState(() => _square = sq);
  }

  @override
  void onWindowMaximize() => _refresh();
  @override
  void onWindowUnmaximize() => _refresh();
  @override
  void onWindowEnterFullScreen() => _refresh();
  @override
  void onWindowLeaveFullScreen() => _refresh();

  @override
  Widget build(BuildContext context) {
    if (!_transparent) return widget.child;
    final r = _square ? BorderRadius.zero : BorderRadius.circular(widget.radius);
    return Container(
      foregroundDecoration: _square ? null : BoxDecoration(borderRadius: r, border: Border.all(color: context.c.borderStrong.withValues(alpha: .7))),
      child: ClipRRect(borderRadius: r, clipBehavior: Clip.antiAlias, child: widget.child),
    );
  }
}
