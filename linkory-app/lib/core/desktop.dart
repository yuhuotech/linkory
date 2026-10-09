import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../shared/close_dialog.dart';
import 'notifications.dart';

/// Windows and Linux draw their own minimise/maximise/close buttons (the title bar is hidden for a
/// cleaner look); macOS keeps its native traffic lights.
bool get hasCustomWindowControls => windowShellActive && !Platform.isMacOS;

/// True only in the real app, after [DesktopShell.init] set up the window plugin. Widget tests run on
/// desktop hosts too (Linux CI!) where the plugin does not exist, so UI code must not assume it.
bool get windowShellActive => isDesktop && DesktopShell.instance != null;

bool get isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// Window, tray, notifications and launch-at-login (PRD 4.10). Desktop only.
class DesktopShell with TrayListener, WindowListener {
  DesktopShell._(this._prefs);
  final SharedPreferences _prefs;

  static DesktopShell? instance;

  /// Reports whether the window is in front of the user (visible, not minimised, focused).
  void Function(bool active)? activeSink;
  bool _focused = true, _minimized = false, _hidden = false;
  void _publishActive() => activeSink?.call(_focused && !_minimized && !_hidden);

  @override
  void onWindowFocus() {
    _focused = true;
    _minimized = false;
    _publishActive();
  }

  @override
  void onWindowBlur() {
    _focused = false;
    _publishActive();
  }

  @override
  void onWindowMinimize() {
    _minimized = true;
    _publishActive();
  }

  @override
  void onWindowRestore() {
    _minimized = false;
    _publishActive();
  }

  /// What the window's close button does: `ask` (prompt), `tray` (hide, keep running) or `quit`.
  /// macOS hides to the tray by default; Windows/Linux ask on the first close and remember the answer.
  String get closeBehavior {
    final v = _prefs.getString('close_behavior');
    if (v == 'ask' || v == 'tray' || v == 'quit') return v!;
    final legacy = _prefs.getBool('close_to_tray'); // older builds
    if (legacy != null) return legacy ? 'tray' : 'quit';
    return Platform.isMacOS ? 'tray' : 'ask';
  }

  Future<void> setCloseBehavior(String v) =>
      _prefs.setString('close_behavior', v);

  /// Whether a tray icon can actually be shown. Always true on macOS/Windows; on Linux it needs a
  /// StatusNotifier host (Ubuntu's AppIndicator extension), otherwise a hidden window is lost.
  bool trayAvailable = true;

  static Future<bool> _detectTray() async {
    if (!Platform.isLinux) return true;
    try {
      return (await Process.run('busctl', [
            '--user',
            'status',
            'org.kde.StatusNotifierWatcher',
          ])).exitCode ==
          0;
    } catch (_) {
      return false;
    }
  }

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
      titleBarStyle:
          TitleBarStyle.hidden, // macOS: traffic lights float over the rail
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    await windowManager.setPreventClose(true);
    windowManager.addListener(s);

    try {
      await localNotifier.setup(
        appName: 'Linkory',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    } catch (e) {
      debugPrint('notifier setup failed: $e');
    }
    s.trayAvailable = await _detectTray();
    try {
      await s._initTray();
    } catch (e) {
      s.trayAvailable = false;
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
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '显示 Linkory'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出'),
        ],
      ),
    );
    trayManager.addListener(this);
  }

  Future<void> showWindow() async {
    // Bring the Dock / taskbar entry back first (macOS: regular activation policy again).
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    _hidden = false;
    _minimized = false;
    _focused = true;
    _publishActive();
  }

  /// Close-to-tray: the process keeps running (tray icon, connection, notifications) but the app
  /// disappears from the Dock / taskbar, so it reads as "quit" until reopened from the tray.
  Future<void> hideToTray() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
    _hidden = true;
    _publishActive();
  }

  // ---- unread indicators ------------------------------------------------------------------

  static const _appTitle = '连信 Linkory';
  static final _unityPath = DBusObjectPath('/com/canonical/unity/launcherentry/1');
  DBusClient? _session;

  /// Dock badge (macOS), launcher count (Ubuntu Dock / Unity API), window title and tray tooltip.
  Future<void> applyUnread(int n) async {
    try {
      await windowManager.setTitle(n > 0 ? '($n) $_appTitle' : _appTitle);
    } catch (_) {}
    try {
      if (!Platform.isLinux) await trayManager.setToolTip(n > 0 ? '$_appTitle · $n 条未读' : _appTitle);
      if (Platform.isMacOS) await trayManager.setTitle(n > 0 ? ' $n' : ''); // number next to the menu-bar icon
    } catch (_) {}
    try {
      if (Platform.isMacOS) await windowManager.setBadgeLabel(n > 0 ? '$n' : '');
      if (Platform.isLinux) await _unityCount(n);
    } catch (e) {
      debugPrint('badge failed: $e');
    }
  }

  /// com.canonical.Unity.LauncherEntry: honoured by Ubuntu Dock / Dash-to-Dock / KDE task manager.
  Future<void> _unityCount(int n) async {
    _session ??= DBusClient.session();
    await _session!.emitSignal(
      path: _unityPath,
      interface: 'com.canonical.Unity.LauncherEntry',
      name: 'Update',
      values: [
        const DBusString('application://com.yuhuo.linkory.desktop'),
        DBusDict.stringVariant({'count': DBusInt64(n), 'count-visible': DBusBoolean(n > 0)}),
      ],
    );
  }

  final _toasts = <String, LocalNotification>{};

  /// Windows / Linux system notification (macOS uses UserNotifications, see MobileMacNotifier).
  Future<void> toast(String peerId, String title, String body, void Function() onClick) async {
    try {
      await _toasts.remove(peerId)?.close(); // one live notification per conversation
      final n = LocalNotification(title: title, body: body.length > 120 ? '${body.substring(0, 120)}…' : body);
      n.onClick = onClick;
      _toasts[peerId] = n;
      await n.show();
    } catch (e) {
      debugPrint('notify failed: $e');
    }
  }

  Future<void> closeToast(String peerId) async {
    try {
      await _toasts.remove(peerId)?.close();
    } catch (_) {}
  }

  // ---- launch at login -------------------------------------------------------------------

  static const _channel = MethodChannel('com.yuhuo.linkory/autostart');
  static final _linuxFile = File(
    '${Platform.environment['HOME']}/.config/autostart/linkory.desktop',
  );
  static const _winKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static Future<bool> autostartEnabled() async {
    try {
      if (Platform.isMacOS) {
        return await _channel.invokeMethod<bool>('isEnabled') ?? false;
      }
      if (Platform.isLinux) return _linuxFile.existsSync();
      if (Platform.isWindows) {
        return (await Process.run('reg', [
              'query',
              _winKey,
              '/v',
              'Linkory',
            ])).exitCode ==
            0;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> setAutostart(bool on) async {
    try {
      if (Platform.isMacOS) {
        await _channel.invokeMethod(
          'set',
          on,
        ); // SMAppService login item (macOS 13+)
      } else if (Platform.isLinux) {
        if (on) {
          await _linuxFile.parent.create(recursive: true);
          await _linuxFile.writeAsString(
            '[Desktop Entry]\nType=Application\nName=Linkory\nExec=${Platform.resolvedExecutable}\nX-GNOME-Autostart-enabled=true\n',
          );
        } else if (_linuxFile.existsSync()) {
          await _linuxFile.delete();
        }
      } else if (Platform.isWindows) {
        await Process.run(
          'reg',
          on
              ? [
                  'add',
                  _winKey,
                  '/v',
                  'Linkory',
                  '/t',
                  'REG_SZ',
                  '/d',
                  '"${Platform.resolvedExecutable}"',
                  '/f',
                ]
              : ['delete', _winKey, '/v', 'Linkory', '/f'],
        );
      }
    } catch (e) {
      debugPrint('autostart failed: $e');
    }
  }

  // ---- listeners -------------------------------------------------------------------------

  @override
  void onWindowClose() async {
    var behavior = closeBehavior;
    if (behavior == 'tray' && !trayAvailable) {
      behavior = 'quit'; // never hide a window nobody can bring back
    }
    if (behavior == 'ask') {
      if (_asking) return;
      _asking = true;
      try {
        final ctx = rootNavigatorKey.currentContext;
        final choice = ctx == null
            ? null
            : await showCloseDialog(ctx, trayAvailable: trayAvailable);
        if (choice == null) return; // cancelled: keep the window
        if (choice.remember) {
          await setCloseBehavior(choice.toTray ? 'tray' : 'quit');
        }
        behavior = choice.toTray ? 'tray' : 'quit';
      } finally {
        _asking = false;
      }
    }
    if (behavior == 'tray') {
      await hideToTray();
    } else {
      await quit();
    }
  }

  bool _asking = false;

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

/// Windows / Linux: toast notifications + launcher badge; macOS: badge only (toasts go through
/// [MobileMacNotifier]).
class DesktopNotifier implements SystemNotifier {
  DesktopNotifier(this.shell, {this.toasts = true});
  final DesktopShell shell;
  final bool toasts;

  @override
  Future<void> show({required String peerId, required String title, required String body, required int count}) async {
    if (!toasts) return;
    await shell.toast(peerId, title, count > 1 ? '[$count 条] $body' : body, () async {
      await shell.showWindow();
      onNotificationTap?.call(peerId);
    });
  }

  @override
  Future<void> clear(String peerId) => shell.closeToast(peerId);

  @override
  Future<void> setUnread(int total) => shell.applyUnread(total);
}
