// Verifies close-to-tray on the real window: after closing, the process must still be alive but the
// Dock/taskbar entry gone. An external script watches the app (see tools/check_tray.sh).
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:linkory_app/core/desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('close hides to the tray and removes the Dock entry; tray can bring it back', (tester) async {
    SharedPreferences.setMockInitialValues({'close_behavior': 'tray'});
    final shell = await DesktopShell.init(await SharedPreferences.getInstance());
    expect(shell, isNotNull);
    await tester.pumpWidget(const SizedBox());
    // ignore: avoid_print
    print('STATE visible pid=$pid');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
    await tester.runAsync(() => windowManager.close());
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    expect(await tester.runAsync(windowManager.isVisible), isFalse);
    // ignore: avoid_print
    print('STATE hidden pid=$pid');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 8)));
    await tester.runAsync(() => shell!.showWindow());
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    expect(await tester.runAsync(windowManager.isVisible), isTrue);
    // ignore: avoid_print
    print('STATE shown-again pid=$pid');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
