// The "other device" of a cross-host test: runs the REAL app (full UI) on this machine, signs in,
// and answers a scripted peer (test/e2e_cross_test.dart on another machine):
//   "ping N"    -> replies "pong N"
//   incoming file offers are accepted; after verification it reports "got <name> <sha256> <mode>"
//   "send-file" -> sends a seeded 6 MB file back and reports "sent <sha256>"
//   "bye"       -> finishes
//
//   xvfb-run -a flutter test integration_test/responder_test.dart -d linux \
//     --dart-define=LINKORY_E2E_URL=http://HOST:8090 --dart-define=LINKORY_X_USER=u --dart-define=LINKORY_X_PASS=p
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:linkory_app/app/app.dart';
import 'package:linkory_app/core/api.dart';
import 'package:linkory_app/core/secrets.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/cross_support.dart';

const url = String.fromEnvironment('LINKORY_E2E_URL');
const user = String.fromEnvironment('LINKORY_X_USER');
const pass = String.fromEnvironment('LINKORY_X_PASS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('responder', (tester) async {
    final dir = await Directory.systemTemp.createTemp('linkory_responder');
    SharedPreferences.setMockInitialValues({'save_dir': '${dir.path}/recv'});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())],
      child: const LinkoryApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
    final c = ProviderScope.containerOf(tester.element(find.byType(LinkoryApp)));

    await tester.runAsync(() async {
      final s = c.read(sessionProvider.notifier);
      try {
        await s.register(url, user, pass);
      } on ApiException catch (e) {
        if (e.code != 'username_taken') rethrow; // the initiator may have registered first
      }
      await s.login(url, user, pass);
    });
    // ignore: avoid_print
    print('RESPONDER signed in as $user on ${c.read(sessionProvider).deviceId}');

    final answered = <String>{}, reported = <String>{};
    var sentFile = false, bye = false;
    final deadline = DateTime.now().add(const Duration(minutes: 4));
    while (!bye && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      final st = c.read(storeProvider);
      final store = c.read(storeProvider.notifier);
      for (final e in st.messages.entries) {
        for (final m in e.value.where((m) => !m.mine)) {
          if (!answered.add(m.clientId)) continue;
          if (m.content.startsWith('ping ')) {
            await store.sendText(e.key, 'pong ${m.content.substring(5)}');
          } else if (m.content == 'send-file' && !sentFile) {
            sentFile = true;
            final made = (await tester.runAsync(() => makeSeededFile('${dir.path}/send/from-responder.bin', 6 * 1024 * 1024, 77)))!;
            await store.sendText(e.key, 'sent ${made.$2}');
            await store.sendFile(e.key, made.$1.path);
          } else if (m.content == 'bye') {
            bye = true;
          }
        }
      }
      for (final t in st.transfers.where((t) => t.receiver == st.self?.id)) {
        if (t.status == 'WAITING_ACCEPT' && reported.add('acc${t.id}')) {
          await store.accept(t);
        } else if (t.status == 'COMPLETED' && t.savedPath != null && reported.add('done${t.id}')) {
          final sum = await tester.runAsync(() => sha256OfFile(t.savedPath!));
          await store.sendText(t.sender, 'got ${t.fileName} $sum ${t.mode}');
        }
      }
    }
    // ignore: avoid_print
    print('RESPONDER DONE bye=$bye');
    expect(bye, isTrue, reason: 'peer never said bye');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
