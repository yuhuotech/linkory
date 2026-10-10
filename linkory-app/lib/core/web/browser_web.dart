import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

String browserOrigin() => web.window.location.origin;

String browserLabel() {
  final ua = web.window.navigator.userAgent;
  final browser = ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('OPR/') || ua.contains('Opera')
          ? 'Opera'
          : ua.contains('Firefox/') || ua.contains('FxiOS/')
              ? 'Firefox'
              : ua.contains('Chrome/') || ua.contains('CriOS/')
                  ? 'Chrome'
                  : ua.contains('Safari/')
                      ? 'Safari'
                      : '浏览器';
  final os = ua.contains('iPhone') || ua.contains('iPad')
      ? 'iOS'
      : ua.contains('Android')
          ? 'Android'
          : ua.contains('Windows')
              ? 'Windows'
              : ua.contains('Mac OS X') || ua.contains('Macintosh')
                  ? 'macOS'
                  : ua.contains('Linux') || ua.contains('X11')
                      ? 'Linux'
                      : '';
  return os.isEmpty ? browser : '$browser · $os';
}

Future<void> browserPersistStorage() async {
  try {
    final s = web.window.navigator.storage;
    if (!(await s.persisted().toDart).toDart) await s.persist().toDart;
  } catch (_) {}
}

void browserWatchActive(void Function(bool active) onChange) {
  bool now() => web.document.visibilityState == 'visible' && web.document.hasFocus();
  void fire(web.Event _) => onChange(now());
  web.window.addEventListener('focus', fire.toJS);
  web.window.addEventListener('blur', fire.toJS);
  web.document.addEventListener('visibilitychange', fire.toJS);
  onChange(now());
}

void browserSetTitle(String title) => web.document.title = title;

bool browserNotifySupported() => (web.window as JSObject).has('Notification');
bool browserNotifyGranted() => browserNotifySupported() && web.Notification.permission == 'granted';

Future<bool> browserNotifyRequest() async {
  if (!browserNotifySupported()) return false;
  if (web.Notification.permission != 'default') return web.Notification.permission == 'granted';
  try {
    return (await web.Notification.requestPermission().toDart).toDart == 'granted';
  } catch (_) {
    return false;
  }
}

final _shown = <String, web.Notification>{};

void browserNotifyShow({required String tag, required String title, required String body, required void Function() onClick}) {
  if (!browserNotifyGranted()) return;
  try {
    _shown.remove(tag)?.close();
    final n = web.Notification(title, web.NotificationOptions(body: body, tag: tag));
    n.onclick = ((web.Event _) {
      web.window.focus();
      n.close();
      onClick();
    }).toJS;
    _shown[tag] = n;
  } catch (_) {} // e.g. Chrome on Android only allows notifications through a service worker
}

void browserNotifyClose(String tag) => _shown.remove(tag)?.close();

Future<bool> browserLockAcquire({required void Function() onLost, bool steal = false}) async {
  if (!(web.window.navigator as JSObject).has('locks')) return true; // insecure context: cannot coordinate, carry on
  final got = Completer<bool>();
  final hold = Completer<JSAny?>(); // never completed: the lock lasts until the tab goes away
  final callback = ((JSAny? lock) {
    if (lock == null) {
      got.complete(false);
      return null;
    }
    got.complete(true);
    return hold.future.toJS;
  }).toJS;
  final request = web.window.navigator.locks.request('linkory-session', web.LockOptions(ifAvailable: !steal, steal: steal), callback);
  unawaited(request.toDart.then<void>((_) {}, onError: (Object _) {
    if (got.isCompleted) onLost(); // rejected after we held it: another tab stole the lock
  }));
  return got.future;
}

void browserReload() => web.window.location.reload();
