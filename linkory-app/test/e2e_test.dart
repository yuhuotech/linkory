// End-to-end: two independent client stacks against a real server.
// Run: LINKORY_E2E_URL=http://127.0.0.1:8090 flutter test test/e2e_test.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/api.dart';
import 'package:linkory_app/core/lan/lan.dart';
import 'package:linkory_app/core/models.dart';
import 'package:linkory_app/core/secrets.dart';
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
  bigTest();
  test('signed-in state survives an app restart (even without a stored access token)', () async {
    final user = 'keep${Random().nextInt(1 << 30)}';
    final tmp = await Directory.systemTemp.createTemp('linkory_keep');
    addTearDown(() => tmp.delete(recursive: true));
    SharedPreferences.setMockInitialValues({'save_dir': tmp.path});
    final prefs = await SharedPreferences.getInstance();
    final secrets1 = Secrets.memory();
    final c1 = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(secrets1)]);
    await c1.read(sessionProvider.notifier).register(url!, user, 'correct-horse-9');
    await c1.read(sessionProvider.notifier).login(url!, user, 'correct-horse-9');
    final devId = c1.read(sessionProvider).deviceId;
    expect(secrets1.get('refresh'), isNotNull);
    c1.dispose(); // "quit the app"

    // "Relaunch": same prefs, credentials from storage — but pretend the access token was never saved.
    final secrets2 = Secrets.memory({'refresh': secrets1.get('refresh')!, 'key_seed': secrets1.get('key_seed') ?? ''});
    final c2 = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(secrets2)]);
    addTearDown(c2.dispose);
    expect(c2.read(sessionProvider).status, AuthStatus.loggedIn);
    expect(c2.read(sessionProvider).deviceId, devId);
    c2.read(sessionProvider.notifier).restoreTokens(c2.read(apiProvider));
    await c2.read(storeProvider.notifier).start();
    await until(() => c2.read(storeProvider).devices.isNotEmpty, what: 'devices load after relaunch');
    expect(c2.read(sessionProvider).status, AuthStatus.loggedIn);
    expect(secrets2.get('access'), isNotNull, reason: 'the renewed access token is stored again');

    // A refresh response lost on the wire: retrying the OLD refresh token must not sign the user out.
    final old = secrets2.get('refresh')!;
    final api = c2.read(apiProvider);
    api.tokens = Tokens('', old);
    await api.request('GET', '/devices'); // 401 -> refresh (rotates) -> retry
    api.tokens = Tokens('', old); // the client "never received" the rotated token and retries with the old one
    await api.request('GET', '/devices');
    expect(c2.read(sessionProvider).status, AuthStatus.loggedIn);
  }, skip: url == null ? 'set LINKORY_E2E_URL' : false, timeout: const Timeout(Duration(seconds: 60)));

  test('files from your own devices are received automatically by default', () async {
    final user = 'auto${Random().nextInt(1 << 30)}';
    final tmp = await Directory.systemTemp.createTemp('linkory_auto');
    addTearDown(() => tmp.delete(recursive: true));
    final a = await client('a', Directory('${tmp.path}/a'));
    final b = await client('b', Directory('${tmp.path}/b'));
    await a.read(sessionProvider.notifier).register(url!, user, 'correct-horse-9');
    await a.read(sessionProvider.notifier).login(url!, user, 'correct-horse-9');
    await b.read(sessionProvider.notifier).login(url!, user, 'correct-horse-9');
    final sa = a.read(storeProvider.notifier), sb = b.read(storeProvider.notifier);
    await sa.start();
    await sb.start();
    expect(b.read(storeProvider).autoAccept, isTrue);
    final idb = b.read(sessionProvider).deviceId;
    await until(() => a.read(storeProvider).isOnline(idb), what: 'presence');
    final f = File('${tmp.path}/auto.txt')..writeAsStringSync('no confirmation needed');
    await sa.sendFile(idb, f.path);
    await until(() => a.read(storeProvider).transfers.any((t) => t.status == 'COMPLETED'), what: 'completed without accept');
    expect(File('${tmp.path}/b/auto.txt').readAsStringSync(), 'no confirmation needed');
    // Both ends can open their copy: the sender its source, the receiver the saved file.
    expect(sa.fileOf(a.read(storeProvider).transfers.first), f.path);
    expect(sb.fileOf(b.read(storeProvider).transfers.first), '${tmp.path}/b/auto.txt');

    // Turning it off brings the confirmation step back.
    await sb.setAutoAccept(false);
    await sa.sendFile(idb, f.path);
    await until(() => b.read(storeProvider).transfers.any((t) => t.status == 'WAITING_ACCEPT'), what: 'invite waits');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(b.read(storeProvider).transfers.where((t) => t.status == 'WAITING_ACCEPT'), hasLength(1));
  }, skip: url == null ? 'set LINKORY_E2E_URL' : false, timeout: const Timeout(Duration(seconds: 60)));

  test('password change keeps this device, signs out the other', () async {
    final user = 'pw${Random().nextInt(1 << 30)}';
    final tmp = await Directory.systemTemp.createTemp('linkory_pw');
    addTearDown(() => tmp.delete(recursive: true));
    final a = await client('a', Directory('${tmp.path}/a'));
    final b = await client('b', Directory('${tmp.path}/b'));
    await a.read(sessionProvider.notifier).register(url!, user, 'correct-horse-9');
    await a.read(sessionProvider.notifier).login(url!, user, 'correct-horse-9');
    await b.read(sessionProvider.notifier).login(url!, user, 'correct-horse-9');
    await a.read(storeProvider.notifier).start();
    await b.read(storeProvider.notifier).start();
    await until(() => a.read(storeProvider).peers.length == 1, what: 'devices');
    await a.read(sessionProvider.notifier).changePassword('correct-horse-9', 'another-pass-77');
    await until(() => b.read(sessionProvider).status == AuthStatus.loggedOut, what: 'b signed out', seconds: 20);
    expect(a.read(sessionProvider).status, AuthStatus.loggedIn);
    await a.read(storeProvider.notifier).loadDevices(); // still authorised
  }, skip: url == null ? 'set LINKORY_E2E_URL' : false, timeout: const Timeout(Duration(seconds: 60)));

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
    await sb.setAutoAccept(false); // this test drives accept/reject by hand
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
    // Same machine, same network: the file should have gone over the direct path.
    final hasLan = (await localLanAddresses()).isNotEmpty;
    expect(a.read(storeProvider).transfers.first.mode, hasLan ? 'lan' : 'relay');
    expect(b.read(storeProvider).transfers.first.mode, hasLan ? 'lan' : 'relay');

    // Relay-only mode forces the server path even on the same network.
    await sa.setTransferMode('relay');
    await sb.setTransferMode('relay');
    final src2 = File('${tmp.path}/relay.bin');
    await src2.writeAsBytes(List<int>.generate(700000, (i) => i & 0xff));
    await sa.sendFile(idb, src2.path);
    await until(() => b.read(storeProvider).transfers.any((t) => t.fileName == 'relay.bin' && t.status == 'WAITING_ACCEPT'), what: 'relay invite');
    await sb.accept(b.read(storeProvider).transfers.firstWhere((t) => t.fileName == 'relay.bin'));
    await until(() => a.read(storeProvider).transfers.firstWhere((t) => t.fileName == 'relay.bin').status == 'COMPLETED', what: 'relay completed', seconds: 30);
    expect(a.read(storeProvider).transfers.firstWhere((t) => t.fileName == 'relay.bin').mode, 'relay');
    expect(await File('${tmp.path}/b/relay.bin').readAsBytes(), await src2.readAsBytes());
    await sa.setTransferMode('auto');
    await sb.setTransferMode('auto');

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

// Large-file check (PRD AT-07/08, 1 GB target): LINKORY_E2E_BIG_MB=1024
final bigMb = int.tryParse(Platform.environment['LINKORY_E2E_BIG_MB'] ?? '');

void bigTest() {
  test('large file relay keeps memory flat and hash matches', () async {
    final user = 'big${Random().nextInt(1 << 30)}';
    const pw = 'correct-horse-9';
    final tmp = await Directory.systemTemp.createTemp('linkory_big');
    addTearDown(() => tmp.delete(recursive: true));
    final a = await client('a', Directory('${tmp.path}/a'));
    final b = await client('b', Directory('${tmp.path}/b'));
    await a.read(sessionProvider.notifier).register(url!, user, pw);
    await a.read(sessionProvider.notifier).login(url!, user, pw);
    await b.read(sessionProvider.notifier).login(url!, user, pw);
    final sa = a.read(storeProvider.notifier), sb = b.read(storeProvider.notifier);
    await sa.start();
    await sb.start();
    final idb = b.read(sessionProvider).deviceId;
    await until(() => a.read(storeProvider).isOnline(idb), what: 'presence');

    final src = File('${tmp.path}/big.bin');
    final sink = src.openWrite();
    final chunk = List<int>.generate(1 << 20, (i) => (i * 31) & 0xff);
    for (var i = 0; i < bigMb!; i++) {
      sink.add(chunk);
    }
    await sink.close();

    final sw = Stopwatch()..start();
    await sa.sendFile(idb, src.path);
    // Auto-accept is on by default: no confirmation step.
    await until(() => b.read(storeProvider).transfers.any((t) => t.status == 'COMPLETED'), what: 'completed', seconds: 900);
    // ignore: avoid_print
    print('transferred $bigMb MB in ${sw.elapsed.inSeconds}s, rss=${ProcessInfo.currentRss ~/ (1 << 20)} MB');
    final dst = File('${tmp.path}/b/big.bin');
    expect(await dst.length(), src.lengthSync());
  }, skip: url == null || bigMb == null ? 'set LINKORY_E2E_URL and LINKORY_E2E_BIG_MB' : false, timeout: const Timeout(Duration(minutes: 20)));
}
