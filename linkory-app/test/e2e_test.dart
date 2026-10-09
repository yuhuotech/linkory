// End-to-end: two independent client stacks against a real server.
// Run: LINKORY_E2E_URL=http://127.0.0.1:8090 flutter test test/e2e_test.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/models.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final url = Platform.environment['LINKORY_E2E_URL'];

Future<void> until(bool Function() ok, {String what = 'condition', int seconds = 15}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timeout waiting for $what');
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

Future<ProviderContainer> client(String name, Directory saveDir) async {
  SharedPreferences.setMockInitialValues({'save_dir': saveDir.path});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('two devices: login, presence, messaging, file transfer', () async {
    final user = 'e2e${Random().nextInt(1 << 30)}';
    const pw = 'correct-horse-9';
    final tmp = await Directory.systemTemp.createTemp('linkory_e2e');
    addTearDown(() => tmp.delete(recursive: true));

    final a = await client('a', Directory('${tmp.path}/a'));
    final b = await client('b', Directory('${tmp.path}/b'));
    await a.read(sessionProvider.notifier).register(url!, user, pw);
    await a.read(sessionProvider.notifier).login(url!, user, pw);
    await b.read(sessionProvider.notifier).login(url!, user, pw);
    expect(a.read(sessionProvider).deviceId, isNot(b.read(sessionProvider).deviceId));

    final sa = a.read(storeProvider.notifier), sb = b.read(storeProvider.notifier);
    await sa.start();
    await sb.start();
    final ida = a.read(sessionProvider).deviceId, idb = b.read(sessionProvider).deviceId;

    // AT-02 / AT-03: both see each other, online.
    await until(() => a.read(storeProvider).peers.length == 1, what: 'a sees b');
    await until(() => a.read(storeProvider).isOnline(idb) && b.read(storeProvider).isOnline(ida), what: 'presence');

    // AT-04: text both ways; delivered status.
    await sa.sendText(idb, 'hello from a');
    await until(() => (b.read(storeProvider).messages[ida] ?? []).any((m) => m.content == 'hello from a'), what: 'b receives');
    await until(() => a.read(storeProvider).messages[idb]!.single.status == MsgStatus.delivered, what: 'delivered ack');
    await sb.sendText(ida, '剪贴板内容', type: 'clipboard');
    await until(() => (a.read(storeProvider).messages[idb] ?? []).any((m) => m.content == '剪贴板内容' && m.type == 'clipboard'), what: 'a receives clipboard');

    // AT-07/08: file transfer a -> b, accepted by b, hash verified.
    final src = File('${tmp.path}/src.bin');
    final rnd = Random(1);
    await src.writeAsBytes(List<int>.generate(3 * 1024 * 1024 + 17, (_) => rnd.nextInt(256)));
    await sa.sendFile(idb, src.path);
    await until(() => b.read(storeProvider).transfers.any((t) => t.status == 'WAITING_ACCEPT'), what: 'invite');
    await sb.accept(b.read(storeProvider).transfers.first);
    await until(() => a.read(storeProvider).transfers.first.status == 'COMPLETED' && b.read(storeProvider).transfers.first.status == 'COMPLETED',
        what: 'transfer completed', seconds: 30);
    final dst = File('${tmp.path}/b/src.bin');
    expect(await dst.readAsBytes(), await src.readAsBytes());

    // Rejected transfer.
    await sa.sendFile(idb, src.path);
    await until(() => b.read(storeProvider).transfers.any((t) => t.status == 'WAITING_ACCEPT'), what: 'second invite');
    await sb.reject(b.read(storeProvider).transfers.firstWhere((t) => t.status == 'WAITING_ACCEPT'));
    await until(() => a.read(storeProvider).transfers.any((t) => t.status == 'REJECTED'), what: 'rejected');

    // AT-11: removing b revokes its credentials.
    await sa.removeDevice(idb);
    await until(() => b.read(sessionProvider).status == AuthStatus.loggedOut, what: 'b logged out after removal', seconds: 20);
  }, skip: url == null ? 'set LINKORY_E2E_URL' : false, timeout: const Timeout(Duration(seconds: 90)));
}
