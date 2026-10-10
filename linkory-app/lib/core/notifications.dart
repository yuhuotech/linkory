import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'log.dart';
import 'web/browser.dart';

/// Is the user looking at the app right now? Desktop: the window is visible, not minimised and
/// focused. Mobile: the app is in the foreground. Drives whether a new message raises a system
/// notification (app in the background) or just an unread badge / in-app banner (app in front).
class AppActive extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool v) {
    if (v != state) state = v;
  }
}

final appActiveProvider = NotifierProvider<AppActive, bool>(AppActive.new);

/// What the store asks the operating system to do. The default does nothing (tests, web).
abstract class SystemNotifier {
  /// Show (or replace) the notification for one conversation. [count] > 1 means several unread.
  Future<void> show({required String peerId, required String title, required String body, required int count});

  /// Remove the notification of a conversation that has been read.
  Future<void> clear(String peerId);

  /// Total unread: Dock badge, taskbar/launcher count, window title, tray tooltip.
  Future<void> setUnread(int total);
}

class NoopNotifier implements SystemNotifier {
  const NoopNotifier();
  @override
  Future<void> show({required String peerId, required String title, required String body, required int count}) async {}
  @override
  Future<void> clear(String peerId) async {}
  @override
  Future<void> setUnread(int total) async {}
}

final systemNotifierProvider = Provider<SystemNotifier>((_) => const NoopNotifier());

/// Set by the app root: open the conversation a notification belongs to (and bring the window forward).
void Function(String peerId)? onNotificationTap;

/// macOS / Android / iOS notifications through the platform's own service (UserNotifications on
/// Apple systems, NotificationManager on Android). Notifications for the same conversation share an
/// id, so a new message replaces the previous one instead of piling up.
class MobileMacNotifier implements SystemNotifier {
  MobileMacNotifier(this._inner);
  final SystemNotifier? _inner; // desktop part: badge count, title, tray (macOS)
  final _plugin = FlutterLocalNotificationsPlugin();
  var _ready = false;

  static bool get supported => !kIsWeb && (Platform.isMacOS || Platform.isAndroid || Platform.isIOS);

  Future<void> init() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) onNotificationTap?.call(id);
        },
      );
      _ready = true;
      if (Platform.isAndroid) {
        await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      }
    } catch (e) {
      Log.warn('notify', 'init failed: ${e.runtimeType}');
    }
  }

  int _id(String peerId) => peerId.hashCode & 0x7fffffff;

  @override
  Future<void> show({required String peerId, required String title, required String body, required int count}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _id(peerId),
        title: title,
        body: count > 1 ? '[$count 条] $body' : body,
        payload: peerId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'messages',
            '新消息',
            channelDescription: '其他设备发来的消息和文件',
            importance: Importance.high,
            priority: Priority.high,
            number: count,
            // Same group for every conversation: the system folds them under one heading.
            groupKey: 'linkory.messages',
          ),
          iOS: DarwinNotificationDetails(threadIdentifier: peerId),
          macOS: DarwinNotificationDetails(threadIdentifier: peerId),
        ),
      );
    } catch (e) {
      Log.warn('notify', 'show failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> clear(String peerId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: _id(peerId));
    } catch (_) {}
  }

  @override
  Future<void> setUnread(int total) async => _inner?.setUnread(total);
}


/// Browser edition: notifications through the Notification API and the unread count in the tab title. Both only
/// work while the page is open (there is no push channel), and notifications need the user's permission.
class WebNotifier implements SystemNotifier {
  static const _title = '连信 Linkory';
  @override
  Future<void> show({required String peerId, required String title, required String body, required int count}) async =>
      browserNotifyShow(tag: peerId, title: title, body: body, onClick: () => onNotificationTap?.call(peerId));
  @override
  Future<void> clear(String peerId) async => browserNotifyClose(peerId);
  @override
  Future<void> setUnread(int total) async => browserSetTitle(total > 0 ? '($total) $_title' : _title);
}
