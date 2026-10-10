// Native client <-> browser client against a real server (the browser side is driven by tools/e2e_web/interop.js).
// Run: tools/e2e_web/run.sh   (builds the web app, starts a server, runs both sides)
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/secrets.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final url = Platform.environment['LINKORY_E2E_URL'];
final dirPath = Platform.environment['LINKORY_E2E_DIR'];
final user = Platform.environment['LINKORY_E2E_USER'] ?? 'interop${Random().nextInt(1 << 20)}';
const pw = 'correct-horse-9';

Future<void> until(bool Function() ok, {String what = 'condition', int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timeout waiting for $what');
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  test('native device and browser device: messages and files both ways', () async {
    final dir = Directory(dirPath!)..createSync(recursive: true);
    File mark(String n) => File('${dir.path}/$n');
    final save = Directory('${dir.path}/native_saved')..createSync();
    SharedPreferences.setMockInitialValues({'save_dir': save.path});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())]);
    addTearDown(c.dispose);
    final s = c.read(sessionProvider.notifier);
    await s.register(url!, user, pw);
    await s.login(url!, user, pw);
    final store = c.read(storeProvider.notifier);
    await store.start();
    expect(c.read(storeProvider).autoAccept, isTrue, reason: 'files from the account\'s own devices are accepted automatically');
    mark('native_ready').writeAsStringSync(c.read(sessionProvider).deviceId);

    // 1. The browser shows up as a device of type "web".
    await until(() => c.read(storeProvider).peers.any((d) => d.type == 'web' && c.read(storeProvider).isOnline(d.id)), what: 'web device online');
    final web = c.read(storeProvider).peers.firstWhere((d) => d.type == 'web');
    expect(web.name, contains('Chrome'));

    // 2. Text both ways.
    await until(() => (c.read(storeProvider).messages[web.id] ?? []).any((m) => m.content == 'hello native 你好'), what: 'text from the browser');
    await store.sendText(web.id, 'hi browser 你好');
    mark('native_replied').writeAsStringSync('1');

    // 3. File browser -> native: accepted automatically, bytes identical, travelled through the relay.
    await until(() => mark('web_sent').existsSync(), what: 'browser file sent');
    final expected = await File('${dir.path}/web_src.bin').readAsBytes();
    final got = File('${save.path}/web_src.bin');
    await until(() => got.existsSync() && c.read(storeProvider).transfers.any((t) => t.fileName == 'web_src.bin' && t.status == 'COMPLETED'), what: 'file from browser');
    expect(await got.readAsBytes(), expected);
    expect(c.read(storeProvider).transfers.firstWhere((t) => t.fileName == 'web_src.bin').mode, 'relay');

    // 4. File native -> browser: the browser must accept it (and choose where to save).
    final rnd = Random(7);
    final src = File('${dir.path}/native_src.bin')..writeAsBytesSync(List<int>.generate(6 * 1024 * 1024 + 123, (_) => rnd.nextInt(256)));
    await store.sendFile(web.id, src.path);
    await until(() => c.read(storeProvider).transfers.any((t) => t.fileName == 'native_src.bin' && t.status == 'COMPLETED'), what: 'native file received by browser', seconds: 90);
    expect(c.read(storeProvider).transfers.firstWhere((t) => t.fileName == 'native_src.bin').mode, 'relay');

    // 5. The browser declines a second one.
    await store.sendFile(web.id, src.path);
    await until(() => c.read(storeProvider).transfers.any((t) => t.fileName == 'native_src.bin' && t.status == 'REJECTED'), what: 'browser rejects', seconds: 60);
    mark('native_done').writeAsStringSync('1');
  }, skip: url == null || dirPath == null ? 'set LINKORY_E2E_URL and LINKORY_E2E_DIR (tools/e2e_web/run.sh)' : false, timeout: const Timeout(Duration(minutes: 4)));
}
