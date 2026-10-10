import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'browser_types.dart';

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

// ---- files ----------------------------------------------------------------------------------

Future<List<BrowserFile>> browserPickFiles() {
  final done = Completer<List<BrowserFile>>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..multiple = true
    ..style.display = 'none';
  web.document.body!.append(input);
  void finish(List<BrowserFile> files) {
    if (!done.isCompleted) done.complete(files);
    input.remove();
  }

  input.onchange = ((web.Event _) {
    final list = input.files;
    finish([
      if (list != null)
        for (var i = 0; i < list.length; i++) BrowserFile(list.item(i)!.name, list.item(i)!.size, list.item(i)!),
    ]);
  }).toJS;
  input.addEventListener('cancel', ((web.Event _) => finish(const [])).toJS);
  input.click(); // must happen inside the user's click
  return done.future;
}

Future<BrowserFile?> browserFileFromUrl(String url, String name) async {
  try {
    final res = await web.window.fetch(url.toJS).toDart;
    final blob = await res.blob().toDart;
    return BrowserFile(name, blob.size, blob);
  } catch (_) {
    return null;
  }
}

Stream<Uint8List> browserReadChunks(BrowserFile f, {int chunk = 4 << 20}) async* {
  final blob = f.handle as web.Blob;
  for (var at = 0; at < f.size; at += chunk) {
    final buf = await blob.slice(at, math.min(at + chunk, f.size)).arrayBuffer().toDart;
    yield buf.toDart.asUint8List();
  }
}

BrowserUpload browserUpload(String url, Map<String, String> headers, BrowserFile f) {
  final xhr = web.XMLHttpRequest()..open('PUT', url);
  headers.forEach((k, v) => xhr.setRequestHeader(k, v));
  final done = Completer<int>();
  void end(int status) {
    if (!done.isCompleted) done.complete(status);
  }

  xhr.onload = ((web.Event _) => end(xhr.status)).toJS;
  xhr.onerror = ((web.Event _) => end(0)).toJS;
  xhr.onabort = ((web.Event _) => end(-1)).toJS;
  xhr.send((f.handle as web.Blob) as JSAny); // the browser streams the Blob from disk
  return BrowserUpload(done.future, () => xhr.abort());
}

Future<BrowserResponse> browserFetch(String url, Map<String, String> headers) async {
  final ctrl = web.AbortController();
  final res = await web.window.fetch(url.toJS, web.RequestInit(method: 'GET', headers: headers.jsify()! as web.HeadersInit, signal: ctrl.signal)).toDart;
  Stream<Uint8List> body() async* {
    final reader = res.body?.getReader() as web.ReadableStreamDefaultReader?;
    if (reader == null) return;
    while (true) {
      final r = await reader.read().toDart;
      if (r.done) return;
      yield (r.value as JSUint8Array).toDart;
    }
  }

  return BrowserResponse(res.status, body(), () => ctrl.abort());
}

bool _canSaveToDisk() => (web.window as JSObject).has('showSaveFilePicker');

Future<BrowserSaveTarget?> browserOpenSaveTarget(String name, int size) async {
  if (_canSaveToDisk()) {
    try {
      final handle = await (web.window as JSObject)
          .callMethodVarArgs<JSPromise<web.FileSystemFileHandle>>('showSaveFilePicker'.toJS, [{'suggestedName': name}.jsify()])
          .toDart;
      return _DiskTarget(await handle.createWritable().toDart);
    } catch (e) {
      return null; // the user dismissed the save dialog (AbortError)
    }
  }
  if (size > browserMemorySaveLimit) throw StateError('too_large');
  return _MemoryTarget(name);
}

class _DiskTarget implements BrowserSaveTarget {
  _DiskTarget(this._w);
  final web.FileSystemWritableFileStream _w;
  @override
  Future<void> write(Uint8List chunk) => _w.write(chunk.toJS).toDart;
  @override
  Future<void> finish() => _w.close().toDart;
  @override
  Future<void> abort() async {
    try {
      await _w.abort().toDart;
    } catch (_) {}
  }
}

class _MemoryTarget implements BrowserSaveTarget {
  _MemoryTarget(this._name);
  final String _name;
  final _parts = <JSAny>[];
  @override
  Future<void> write(Uint8List chunk) async => _parts.add(web.Blob([chunk.toJS].toJS)); // Blobs may be spilled to disk by the browser
  @override
  Future<void> finish() async {
    final url = web.URL.createObjectURL(web.Blob(_parts.toJS));
    final a = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = _name
      ..style.display = 'none';
    web.document.body!.append(a);
    a.click();
    a.remove();
    Timer(const Duration(minutes: 2), () => web.URL.revokeObjectURL(url));
  }

  @override
  Future<void> abort() async => _parts.clear();
}
