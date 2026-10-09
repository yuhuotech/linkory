// Initiator of the cross-host end-to-end: drives a real app running on another machine
// (integration_test/responder_test.dart). Orchestrated by tools/cross_e2e.sh.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/models.dart';
import 'package:linkory_app/core/secrets.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cross_support.dart';

final url = Platform.environment['LINKORY_E2E_URL'];
final user = Platform.environment['LINKORY_X_USER'];
final pass = Platform.environment['LINKORY_X_PASS'];
final expectLan = Platform.environment['LINKORY_X_EXPECT_LAN'] == '1';

Future<void> until(bool Function() ok, String what, {int seconds = 30, String Function()? debug}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  var n = 0;
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timeout waiting for $what${debug == null ? '' : ' [${debug()}]'}');
    if (debug != null && ++n % 100 == 0) {
      // ignore: avoid_print
      print('waiting for $what: ${debug()}');
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  test('cross-host: this machine <-> real app on another machine', () async {
    final dir = await Directory.systemTemp.createTemp('linkory_cross');
    addTearDown(() => dir.delete(recursive: true));
    SharedPreferences.setMockInitialValues({'save_dir': '${dir.path}/recv'});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())]);
    addTearDown(c.dispose);
    final s = c.read(sessionProvider.notifier);
    try {
      await s.register(url!, user!, pass!);
    } catch (_) {}
    await s.login(url!, user!, pass!);
    final store = c.read(storeProvider.notifier);
    await store.start();
    St st() => c.read(storeProvider);

    // The responder registers its own device (type linux) and comes online.
    await until(() => st().peers.any((d) => st().isOnline(d.id)), 'peer device online', seconds: 240,
        debug: () => 'link=${st().link.name} devices=${st().devices.map((d) => '${d.name}/${d.type}/cur=${d.current}').toList()} online=${st().online.length}');
    final peer = st().peers.firstWhere((d) => st().isOnline(d.id));
    // ignore: avoid_print
    print('PEER ${peer.name} (${peer.type}) ${peer.osVersion}');

    // 1) messages round-trip
    for (var i = 1; i <= 3; i++) {
      await store.sendText(peer.id, 'ping $i');
    }
    await until(() => ['pong 1', 'pong 2', 'pong 3'].every((p) => (st().messages[peer.id] ?? []).any((m) => !m.mine && m.content == p)), 'pongs');
    await until(() => (st().messages[peer.id] ?? []).where((m) => m.mine).every((m) => m.status == MsgStatus.delivered), 'delivered acks');

    // 2) file: this machine -> responder
    final (f, sum) = await makeSeededFile('${dir.path}/send/to-responder.bin', 8 * 1024 * 1024 + 11, 5);
    await store.sendFile(peer.id, f.path);
    await until(() => st().transfers.any((t) => t.fileName == 'to-responder.bin' && !t.active), 'upload finished', seconds: 90);
    final up = st().transfers.firstWhere((t) => t.fileName == 'to-responder.bin');
    expect(up.status, 'COMPLETED');
    await until(() => (st().messages[peer.id] ?? []).any((m) => !m.mine && m.content.startsWith('got to-responder.bin')), 'receipt', seconds: 30);
    final got = (st().messages[peer.id] ?? []).firstWhere((m) => !m.mine && m.content.startsWith('got to-responder.bin')).content.split(' ');
    expect(got[2], sum, reason: 'responder computed a different SHA-256');
    // ignore: avoid_print
    print('UPLOAD ok mode=${up.mode} (responder saw ${got[3]})');

    // 3) file: responder -> this machine (we accept)
    await store.sendText(peer.id, 'send-file');
    await until(() => st().transfers.any((t) => t.fileName == 'from-responder.bin' && t.status == 'WAITING_ACCEPT'), 'offer from responder', seconds: 30);
    await store.accept(st().transfers.firstWhere((t) => t.fileName == 'from-responder.bin'));
    await until(() => st().transfers.any((t) => t.fileName == 'from-responder.bin' && t.status == 'COMPLETED'), 'download finished', seconds: 90);
    final down = st().transfers.firstWhere((t) => t.fileName == 'from-responder.bin');
    final (_, wantSum) = await makeSeededFile('${dir.path}/expect.bin', 6 * 1024 * 1024, 77);
    expect(await sha256OfFile(down.savedPath!), wantSum);
    // ignore: avoid_print
    print('DOWNLOAD ok mode=${down.mode}');

    if (expectLan) {
      expect(up.mode, 'lan', reason: 'expected a direct same-network transfer');
      expect(down.mode, 'lan');
    }
    await store.sendText(peer.id, 'bye');
    await Future<void>.delayed(const Duration(seconds: 1));
  }, skip: url == null || user == null ? 'run via tools/cross_e2e.sh' : false, timeout: const Timeout(Duration(minutes: 8)));
}

typedef St = AppState;
