import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/lan/lan.dart';

const tid = '0f8fad5b-d9cb-469f-a165-70867728950e';

Uint8List secretOf(int seed) => Uint8List.fromList(List.generate(32, (i) => (i * seed) & 0xff));

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('linkory_lan'));
  tearDown(() => tmp.delete(recursive: true));

  Future<(File, String)> makeFile(int size) async {
    final f = File('${tmp.path}/src.bin');
    final r = Random(7);
    await f.writeAsBytes(List.generate(size, (_) => r.nextInt(256)));
    return (f, sha256.convert(await f.readAsBytes()).toString());
  }

  LanHooks hooks(LanIncoming inc, {List<String>? log, bool accept = true}) => LanHooks(
        lookup: (id) => id == tid ? inc : null,
        onStart: (_) => log?.add('start'),
        onVerified: (_, part) async {
          log?.add('verified');
          if (accept) await part.rename('${tmp.path}/out.bin');
          return accept;
        },
        onFailed: (_, {required corrupt}) => log?.add(corrupt ? 'corrupt' : 'interrupted'),
      );

  test('encrypted transfer round-trip with verification', () async {
    final (src, sum) = await makeFile(3 * 1024 * 1024 + 123);
    final secret = secretOf(3);
    final log = <String>[];
    final inc = LanIncoming(taskId: tid, secret: secret, size: src.lengthSync(), sha256: sum, part: File('${tmp.path}/.part'));
    final l = await LanListener.bind(hooks(inc, log: log));
    addTearDown(l.close);
    var last = 0;
    final out = await lanSend(addrs: ['127.0.0.1'], port: l.port, taskId: tid, secret: secret, file: src, onProgress: (b) => last = b);
    expect(out, LanSendOutcome.ok);
    expect(last, src.lengthSync());
    expect(log, ['start', 'verified']);
    expect(await File('${tmp.path}/out.bin').readAsBytes(), await src.readAsBytes());
  });

  test('wrong secret is rejected before any data flows', () async {
    final (src, sum) = await makeFile(1000);
    final log = <String>[];
    final inc = LanIncoming(taskId: tid, secret: secretOf(3), size: 1000, sha256: sum, part: File('${tmp.path}/.part'));
    final l = await LanListener.bind(hooks(inc, log: log));
    addTearDown(l.close);
    final out = await lanSend(addrs: ['127.0.0.1'], port: l.port, taskId: tid, secret: secretOf(5), file: src);
    expect(out, isNot(LanSendOutcome.ok));
    expect(log, isEmpty);
  });

  test('unknown task is dropped', () async {
    final (src, sum) = await makeFile(1000);
    final inc = LanIncoming(taskId: tid, secret: secretOf(3), size: 1000, sha256: sum, part: File('${tmp.path}/.part'));
    final l = await LanListener.bind(hooks(inc));
    addTearDown(l.close);
    final out = await lanSend(addrs: ['127.0.0.1'], port: l.port, taskId: '11111111-1111-4111-8111-111111111111', secret: secretOf(3), file: src);
    expect(out, LanSendOutcome.failed);
  });

  test('wrong file hash is refused and the temp file removed', () async {
    final (src, _) = await makeFile(500000);
    final log = <String>[];
    final inc = LanIncoming(taskId: tid, secret: secretOf(3), size: 500000, sha256: '0' * 64, part: File('${tmp.path}/.part'));
    final l = await LanListener.bind(hooks(inc, log: log));
    addTearDown(l.close);
    final out = await lanSend(addrs: ['127.0.0.1'], port: l.port, taskId: tid, secret: secretOf(3), file: src);
    expect(out, LanSendOutcome.rejected);
    expect(log, ['start', 'corrupt']);
    expect(File('${tmp.path}/.part').existsSync(), isFalse);
  });

  test('interrupted transfer resumes from the received offset', () async {
    final (src, sum) = await makeFile(4 * 1024 * 1024);
    final secret = secretOf(9);
    final log = <String>[];
    final inc = LanIncoming(taskId: tid, secret: secret, size: src.lengthSync(), sha256: sum, part: File('${tmp.path}/.part'));
    final l = await LanListener.bind(hooks(inc, log: log));
    addTearDown(l.close);
    // First attempt: abort after ~1 MB.
    var stop = false;
    final first = await lanSend(
        addrs: ['127.0.0.1'], port: l.port, taskId: tid, secret: secret, file: src, onProgress: (b) => stop = b > 1024 * 1024, cancelled: () => stop);
    expect(first, LanSendOutcome.failed);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final partial = File('${tmp.path}/.part').lengthSync();
    expect(partial, greaterThan(0));
    expect(partial, lessThan(src.lengthSync()));
    // Second attempt continues at the offset the receiver reports.
    var firstProgress = -1;
    final second = await lanSend(
        addrs: ['127.0.0.1'], port: l.port, taskId: tid, secret: secret, file: src, onProgress: (b) => firstProgress = firstProgress < 0 ? b : firstProgress);
    expect(second, LanSendOutcome.ok);
    expect(firstProgress, partial);
    expect(await File('${tmp.path}/out.bin').readAsBytes(), await src.readAsBytes());
  });

  test('falls through to a reachable candidate address', () async {
    final (src, sum) = await makeFile(10000);
    final inc = LanIncoming(taskId: tid, secret: secretOf(3), size: 10000, sha256: sum, part: File('${tmp.path}/.part'));
    final l = await LanListener.bind(hooks(inc));
    addTearDown(l.close);
    final out = await lanSend(addrs: ['10.255.255.1', '127.0.0.1'], port: l.port, taskId: tid, secret: secretOf(3), file: src);
    expect(out, LanSendOutcome.ok);
  });

  // Interoperability with the Rust reference implementation (linkory-core). Build it first:
  //   cd linkory-core && cargo build --release
  final rustBin = Platform.environment['LINKORY_LAN_BIN'] ?? '../linkory-core/target/release/linkory-lan';
  final hasRust = File(rustBin).existsSync();

  group('interop with linkory-core (Rust)', () {
    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

    test('Dart sender -> Rust receiver', () async {
      final (src, sum) = await makeFile(2 * 1024 * 1024 + 9);
      final secret = secretOf(11);
      final part = '${tmp.path}/rust.part';
      final p = await Process.start(rustBin, [
        'recv', '--listen', '0', '--task', tid, '--secret', hex(secret), '--size', '${src.lengthSync()}', '--sha256', sum, '--part', part,
      ]);
      final lines = <String>[];
      final portReady = Completer<int>();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        lines.add(l);
        if (l.startsWith('PORT ') && !portReady.isCompleted) portReady.complete(int.parse(l.split(' ')[1]));
      });
      final port = await portReady.future.timeout(const Duration(seconds: 10));
      final out = await lanSend(addrs: ['127.0.0.1'], port: port, taskId: tid, secret: secret, file: src);
      expect(out, LanSendOutcome.ok);
      expect(await p.exitCode, 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(lines, contains('VERIFIED'));
      expect(await File(part).readAsBytes(), await src.readAsBytes());
    }, skip: hasRust ? false : 'build linkory-core first');

    test('Rust sender -> Dart receiver', () async {
      final (src, sum) = await makeFile(2 * 1024 * 1024 + 9);
      final secret = secretOf(13);
      final inc = LanIncoming(taskId: tid, secret: secret, size: src.lengthSync(), sha256: sum, part: File('${tmp.path}/.part'));
      final log = <String>[];
      final l = await LanListener.bind(hooks(inc, log: log));
      addTearDown(l.close);
      final r = await Process.run(rustBin, ['send', '--addr', '127.0.0.1:${l.port}', '--task', tid, '--secret', hex(secret), '--file', src.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(log, ['start', 'verified']);
      expect(await File('${tmp.path}/out.bin').readAsBytes(), await src.readAsBytes());
    }, skip: hasRust ? false : 'build linkory-core first');
  });
}
