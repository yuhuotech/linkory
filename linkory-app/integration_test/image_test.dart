// Runs the real app (real engine, fonts, window) against a live server and saves screenshots.
//   LINKORY_E2E_URL=http://127.0.0.1:8090 flutter test integration_test/app_test.dart -d macos
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:linkory_app/app/app.dart';
import 'package:linkory_app/core/secrets.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:linkory_app/features/transfers/transfer_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const url = String.fromEnvironment('LINKORY_E2E_URL', defaultValue: 'http://127.0.0.1:8090');

// On devices where the sandbox is wiped after the run, an external script (adb screencap) can grab
// the screen while the test holds each state for this many seconds.
const holdSeconds = int.fromEnvironment('LINKORY_HOLD_SECONDS', defaultValue: 0);

Future<ProviderContainer> headless(Directory dir) async {
  SharedPreferences.setMockInitialValues({'save_dir': dir.path});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())]);
  addTearDown(c.dispose);
  return c;
}

int _crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1);
    }
  }
  return c ^ 0xffffffff;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real app: a received photo previews inline and opens full size', (tester) async {
    final out = await Directory.systemTemp.createTemp('linkory_img');
    // ignore: avoid_print
    print('SHOTS ${out.path}');
    final user = 'img${Random().nextInt(1 << 30)}';
    const pw = 'correct-horse-9';

    final peer = await headless(Directory('${out.path}/peer'));
    await peer.read(sessionProvider.notifier).register(url, user, pw);
    await peer.read(sessionProvider.notifier).login(url, user, pw);
    await peer.read(storeProvider.notifier).start();

    SharedPreferences.setMockInitialValues({'save_dir': '${out.path}/app'});
    final prefs = await SharedPreferences.getInstance();
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())],
      child: RepaintBoundary(key: key, child: const LinkoryApp()),
    ));
    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await tester.runAsync(() => b.toImage(pixelRatio: 1));
      final bytes = await tester.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
      File('${out.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    final container = ProviderScope.containerOf(tester.element(find.byType(LinkoryApp)));
    await tester.runAsync(() => container.read(sessionProvider.notifier).login(url, user, pw));
    for (var i = 0; i < 50 && container.read(storeProvider).peers.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final appId = container.read(sessionProvider).deviceId;

    // A 4000x3000 "photo" (a smooth gradient with a sun and a hill), written as a PNG by hand so the
    // test does not depend on GPU readback speed.
    final photo = File('${out.path}/风景-4000x3000.png');
    await tester.runAsync(() async {
      const w = 4000, h = 3000;
      final raw = Uint8List(h * (1 + w * 3));
      var o = 0;
      for (var y = 0; y < h; y++) {
        raw[o++] = 0; // filter: none
        for (var x = 0; x < w; x++) {
          var r = 14 + 235 * x ~/ w, g = 165 - 60 * y ~/ h, b = 233 - 190 * x ~/ w;
          final dx = x - 2800, dy = y - 900;
          if (dx * dx + dy * dy < 420 * 420) {
            r = 253;
            g = 230;
            b = 138;
          } else if (y > 2200 + (x % 800 < 400 ? 0 : 60)) {
            r = 20;
            g = 83;
            b = 45;
          }
          raw[o++] = r;
          raw[o++] = g;
          raw[o++] = b;
        }
      }
      final z = ZLibCodec(level: 1).encode(raw);
      List<int> chunk(String t, List<int> d) {
        final c = ByteData(4)..setUint32(0, d.length);
        final body = [...t.codeUnits, ...d];
        final crc = ByteData(4)..setUint32(0, _crc32(body));
        return [...c.buffer.asUint8List(), ...body, ...crc.buffer.asUint8List()];
      }
      final ihdr = ByteData(13)
        ..setUint32(0, w)
        ..setUint32(4, h)
        ..setUint8(8, 8)
        ..setUint8(9, 2);
      photo.writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...chunk('IHDR', ihdr.buffer.asUint8List()), ...chunk('IDAT', z), ...chunk('IEND', const [])]);
      await peer.read(storeProvider.notifier).sendFile(appId, photo.path);
    });
    // The app auto-accepts; wait for it to complete.
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      final t = container.read(storeProvider).transfers;
      if (t.isNotEmpty && t.first.status == 'COMPLETED') break;
    }
    final peerId = container.read(storeProvider).peers.first.id;
    await tester.runAsync(() => container.read(storeProvider.notifier).selectPeer(peerId));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump(const Duration(seconds: 1));
    await shot('1_inline_decoding');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3))); // let the 12 MP PNG finish decoding
    await tester.pump(const Duration(milliseconds: 500));
    await shot('1_inline');

    final sw = Stopwatch()..start();
    await tester.tap(find.byType(ImagePreview));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print('VIEWER opened in ${sw.elapsedMilliseconds}ms');
    await shot('2_viewer');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭（Esc）'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
