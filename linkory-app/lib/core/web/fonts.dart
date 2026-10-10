import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Browser edition: register the bundled Chinese font before the first frame (see web/fonts/README.md).
/// Never fails the start-up: without it the text falls back to the engine's default fonts.
Future<void> loadWebFonts() async {
  if (!kIsWeb) return;
  try {
    final loader = FontLoader('NotoSansSC');
    for (final f in const ['NotoSansSC-Regular.ttf', 'NotoSansSC-Bold.ttf']) {
      loader.addFont(http.get(Uri.base.resolve('fonts/$f')).then((r) {
        if (r.statusCode != 200) throw StateError('font $f: ${r.statusCode}');
        return ByteData.sublistView(r.bodyBytes);
      }));
    }
    await loader.load().timeout(const Duration(seconds: 20));
  } catch (e) {
    debugPrint('web fonts unavailable: $e');
  }
}
