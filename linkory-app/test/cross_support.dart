// Shared by the cross-host end-to-end pair: test/e2e_cross_test.dart (initiator, runs anywhere) and
// integration_test/responder_test.dart (responder, runs the real app on another machine).
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Deterministic file content so both ends can predict the SHA-256 without exchanging the file.
Future<(File, String)> makeSeededFile(String path, int size, int seed) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final r = Random(seed);
  final sink = f.openWrite();
  var left = size;
  while (left > 0) {
    final n = min(left, 1 << 20);
    sink.add(List<int>.generate(n, (_) => r.nextInt(256)));
    left -= n;
  }
  await sink.close();
  return (f, (await sha256.bind(f.openRead()).first).toString());
}

Future<String> sha256OfFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();
