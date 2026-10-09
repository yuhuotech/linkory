import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/app/app.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';

import 'support.dart';

Future<void> pumpApp(WidgetTester t, AppState s, {Brightness b = Brightness.light, AuthStatus auth = AuthStatus.loggedIn}) async {
  t.view.physicalSize = const Size(1200, 780);
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = b;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  await t.pumpWidget(ProviderScope(overrides: await overrides(s, auth: auth), child: const LinkoryApp()));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('three columns: rail | device list | chat', (t) async {
    await pumpApp(t, fixtureState());
    expect(find.text('办公室 Windows'), findsWidgets);
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('文件我放在共享盘了，你看一下'), findsOneWidget);
    expect(find.text('发送失败'), findsOneWidget);
    expect(find.text('季度报表-final.xlsx'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/chat_light.png'));
  });

  testWidgets('dark theme', (t) async {
    await pumpApp(t, fixtureState(), b: Brightness.dark);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/chat_dark.png'));
  });

  testWidgets('other sections render', (t) async {
    for (final s in [Section.devices, Section.transfers, Section.settings]) {
      await pumpApp(t, fixtureState(section: s));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${s.name}_light.png'));
    }
  });

  testWidgets('login page', (t) async {
    await pumpApp(t, fixtureState(), auth: AuthStatus.loggedOut);
    expect(find.text('登录'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/login_light.png'));
  });

  testWidgets('composer sends on Enter', (t) async {
    await pumpApp(t, fixtureState());
    await t.enterText(find.byType(TextField).last, 'hello');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    final c = ProviderScope.containerOf(t.element(find.byType(LinkoryApp)));
    expect((c.read(storeProvider.notifier) as FakeStore).sent, ['hello']);
  });
}
