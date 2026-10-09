import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'version.dart';

/// Local file log (PRD 4.10). Never log passwords, tokens or message/file contents (PRD §7).
class Log {
  static File? _file;
  static const _maxBytes = 2 * 1024 * 1024;

  static String? get dir => _file?.parent.path;

  static Future<void> init() async {
    if (kIsWeb) return;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}logs');
      await d.create(recursive: true);
      final f = File('${d.path}${Platform.pathSeparator}linkory.log');
      if (f.existsSync() && f.lengthSync() > _maxBytes) {
        final old = File('${f.path}.1');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
      _file = f;
      info('app', 'started v$appVersion ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    } catch (_) {}
  }

  static void info(String tag, String msg) => _w('INFO', tag, msg);
  static void warn(String tag, String msg) => _w('WARN', tag, msg);
  static void error(String tag, Object e, [StackTrace? st]) => _w('ERROR', tag, '$e${st == null ? '' : '\n$st'}');

  static void _w(String level, String tag, String msg) {
    debugPrint('[$level] $tag $msg');
    try {
      _file?.writeAsStringSync('${DateTime.now().toIso8601String()} $level $tag $msg\n', mode: FileMode.append);
    } catch (_) {}
  }
}
