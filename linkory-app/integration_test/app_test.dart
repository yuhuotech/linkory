// Runs the real app (real engine, fonts, window) against a live server and saves screenshots.
//   LINKORY_E2E_URL=http://127.0.0.1:8090 flutter test integration_test/app_test.dart -d macos
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:linkory_app/app/app.dart';
import 'package:linkory_app/core/secrets.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const url = String.fromEnvironment('LINKORY_E2E_URL', defaultValue: 'http://127.0.0.1:8090');

Future<ProviderContainer> headless(Directory dir) async {
  SharedPreferences.setMockInitialValues({'save_dir': dir.path});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real app: login, see peer, receive message and file offer', (tester) async {
    final out = await Directory.systemTemp.createTemp('linkory_shots');
    // ignore: avoid_print
    print('SHOTS ${out.path}');
    final user = 'ui${Random().nextInt(1 << 30)}';
    const pw = 'correct-horse-9';

    // Second device, headless, signed in to the same account.
    final peer = await headless(Directory('${out.path}/peer'));
    await peer.read(sessionProvider.notifier).register(url, user, pw);
    await peer.read(sessionProvider.notifier).login(url, user, pw);
    await peer.read(storeProvider.notifier).start();

    // The app under test.
    SharedPreferences.setMockInitialValues({'save_dir': '${out.path}/app'});
    final prefs = await SharedPreferences.getInstance();
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())],
      child: RepaintBoundary(key: key, child: const LinkoryApp()),
    ));
    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 400));
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await tester.runAsync(() => b.toImage(pixelRatio: 1));
      final bytes = await tester.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
      File('${out.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    await tester.pump(const Duration(seconds: 1));
    await shot('1_login');

    final container = ProviderScope.containerOf(tester.element(find.byType(LinkoryApp)));
    await tester.runAsync(() => container.read(sessionProvider.notifier).login(url, user, pw));
    await tester.pump(const Duration(seconds: 2));
    // Wait for the peer to show up.
    for (var i = 0; i < 50 && container.read(storeProvider).peers.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await shot('2_list');

    final appId = container.read(sessionProvider).deviceId;
    await tester.runAsync(() async {
      await peer.read(storeProvider.notifier).sendText(appId, '你好，这是来自另一台设备的消息 👋');
      await peer.read(storeProvider.notifier).sendText(appId, 'https://linkory.example.com/invite/8f3a2c', type: 'clipboard');
      final f = File('${out.path}/报告.pdf')..writeAsBytesSync(List.filled(2 * 1024 * 1024, 7));
      await peer.read(storeProvider.notifier).sendFile(appId, f.path);
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump(const Duration(seconds: 1));
    final peerId = container.read(storeProvider).peers.first.id;
    await tester.runAsync(() => container.read(storeProvider.notifier).selectPeer(peerId));
    await tester.pump(const Duration(seconds: 1));
    await shot('3_chat');

    for (final s in [Section.devices, Section.transfers, Section.settings]) {
      container.read(storeProvider.notifier).setSection(s);
      await tester.pump(const Duration(milliseconds: 500));
      await shot('4_${s.name}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
