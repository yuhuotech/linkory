import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Windows and Linux draw their own minimise/maximise/close buttons (the title bar is hidden for a
/// cleaner look); macOS keeps its native traffic lights.
bool get hasCustomWindowControls => isDesktop && !Platform.isMacOS;

bool get isDesktop => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// Window, tray, notifications and launch-at-login (PRD 4.10). Desktop only.
class DesktopShell with TrayListener, WindowListener {
  DesktopShell._(this._prefs);
  final SharedPreferences _prefs;

  static DesktopShell? instance;

  /// Closing the window hides it to the tray instead of quitting. On by default on macOS/Windows;
  /// off on Linux, where GNOME shows no tray icon without an extension and a hidden window could
  /// not be brought back.
  bool get closeToTray => _prefs.getBool('close_to_tray') ?? defaultCloseToTray;
  static bool get defaultCloseToTray => !Platform.isLinux;
  Future<void> setCloseToTray(bool v) => _prefs.setBool('close_to_tray', v);

  static Future<DesktopShell?> init(SharedPreferences prefs) async {
    if (!isDesktop) return null;
    final s = DesktopShell._(prefs);
    instance = s;

    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1100, 720),
      minimumSize: Size(860, 560),
      center: true,
      title: '连信 Linkory',
      titleBarStyle: TitleBarStyle.hidden, // macOS: traffic lights float over the rail
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    await windowManager.setPreventClose(true);
    windowManager.addListener(s);

    try {
      await localNotifier.setup(appName: 'Linkory', shortcutPolicy: ShortcutPolicy.requireCreate);
    } catch (e) {
      debugPrint('notifier setup failed: $e');
    }
    try {
      await s._initTray();
    } catch (e) {
      debugPrint('tray setup failed: $e');
    }
    return s;
  }

  Future<void> _initTray() async {
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/icons/app.ico'
          : Platform.isMacOS
              ? 'assets/icons/tray@2x.png'
              : 'assets/icons/app_32.png',
      isTemplate: Platform.isMacOS, // adapts to light/dark menu bar
    );
    if (!Platform.isLinux) await trayManager.setToolTip('连信 Linkory');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '显示 Linkory'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
    trayManager.addListener(this);
  }

  Future<void> showWindow() async {
    // Bring the Dock / taskbar entry back first (macOS: regular activation policy again).
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  /// Close-to-tray: the process keeps running (tray icon, connection, notifications) but the app
  /// disappears from the Dock / taskbar, so it reads as "quit" until reopened from the tray.
  Future<void> hideToTray() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  /// Notify only when the user is not already looking at the app.
  Future<void> notify(String title, String body) async {
    try {
      if (await windowManager.isVisible() && await windowManager.isFocused()) return;
      final n = LocalNotification(title: title, body: body.length > 120 ? '${body.substring(0, 120)}…' : body);
      n.onClick = showWindow;
      await n.show();
    } catch (e) {
      debugPrint('notify failed: $e');
    }
  }

  // ---- launch at login -------------------------------------------------------------------

  static const _channel = MethodChannel('com.yuhuo.linkory/autostart');
  static final _linuxFile = File('${Platform.environment['HOME']}/.config/autostart/linkory.desktop');
  static const _winKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static Future<bool> autostartEnabled() async {
    try {
      if (Platform.isMacOS) return await _channel.invokeMethod<bool>('isEnabled') ?? false;
      if (Platform.isLinux) return _linuxFile.existsSync();
      if (Platform.isWindows) return (await Process.run('reg', ['query', _winKey, '/v', 'Linkory'])).exitCode == 0;
    } catch (_) {}
    return false;
  }

  static Future<void> setAutostart(bool on) async {
    try {
      if (Platform.isMacOS) {
        await _channel.invokeMethod('set', on); // SMAppService login item (macOS 13+)
      } else if (Platform.isLinux) {
        if (on) {
          await _linuxFile.parent.create(recursive: true);
          await _linuxFile.writeAsString(
              '[Desktop Entry]\nType=Application\nName=Linkory\nExec=${Platform.resolvedExecutable}\nX-GNOME-Autostart-enabled=true\n');
        } else if (_linuxFile.existsSync()) {
          await _linuxFile.delete();
        }
      } else if (Platform.isWindows) {
        await Process.run(
            'reg', on ? ['add', _winKey, '/v', 'Linkory', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}"', '/f'] : ['delete', _winKey, '/v', 'Linkory', '/f']);
      }
    } catch (e) {
      debugPrint('autostart failed: $e');
    }
  }

  // ---- listeners -------------------------------------------------------------------------

  @override
  void onWindowClose() async {
    if (closeToTray) {
      await hideToTray();
    } else {
      await quit();
    }
  }

  Future<void> quit() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'quit':
        quit();
    }
  }
}
