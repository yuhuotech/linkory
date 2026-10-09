// Real window: with close_behavior=ask, clicking close shows the dialog; confirming "hide to tray"
// hides the window; cancelling keeps it; "quit" would exit (not exercised here).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:linkory_app/app/app.dart';
import 'package:linkory_app/core/desktop.dart';
import 'package:linkory_app/core/secrets.dart';
import 'package:linkory_app/core/session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('first close asks; default hides to tray and remembers', (tester) async {
    SharedPreferences.setMockInitialValues({'close_behavior': 'ask'});
    final prefs = await SharedPreferences.getInstance();
    final shell = (await DesktopShell.init(prefs))!;
    await tester.pumpWidget(ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs), secretsProvider.overrideWithValue(Secrets.memory())],
      child: const LinkoryApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(shell.closeBehavior, 'ask');

    // 1) Close -> dialog; Cancel keeps the window.
    await tester.runAsync(() => windowManager.close());
    await tester.pumpAndSettle();
    expect(find.text('关闭连信'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(windowManager.isVisible), isTrue);

    // 2) Close -> dialog -> OK with defaults (hide to tray, remember).
    await tester.runAsync(() => windowManager.close());
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    expect(await tester.runAsync(windowManager.isVisible), isFalse);
    expect(shell.closeBehavior, 'tray');
    // ignore: avoid_print
    print('STATE hidden-after-dialog');

    // 3) Remembered: the next close hides without asking.
    await tester.runAsync(() => shell.showWindow());
    await tester.pumpAndSettle();
    await tester.runAsync(() => windowManager.close());
    await tester.pumpAndSettle();
    expect(find.text('关闭连信'), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    expect(await tester.runAsync(windowManager.isVisible), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
