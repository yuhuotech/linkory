import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/app/app.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:linkory_app/shared/widgets.dart' show debugShowWindowControls;

import 'support.dart';

Future<void> pumpApp(WidgetTester t, AppState s,
    {Brightness b = Brightness.light, AuthStatus auth = AuthStatus.loggedIn, Size size = const Size(1200, 780)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = b;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  await t.pumpWidget(ProviderScope(key: UniqueKey(), overrides: await overrides(s, auth: auth), child: const LinkoryApp()));
  // Wait for the brand asset decoder before comparing the first golden.
  await t.runAsync(() => precacheImage(
        const AssetImage('assets/icons/app_128.png'),
        t.element(find.byType(MaterialApp)),
      ));
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

  testWidgets('signed out: full UI is browsable, sign-in is opt-in', (t) async {
    await pumpApp(t, const AppState(), auth: AuthStatus.loggedOut);
    // Default page is a welcome screen with entry points, not a forced login form.
    expect(find.text('欢迎使用连信'), findsOneWidget);
    expect(find.text('服务器地址'), findsNothing);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/guest_welcome_light.png'));

    // Other sections are reachable and explain what signing in unlocks.
    await t.tap(find.byTooltip('设备管理'));
    await t.pumpAndSettle();
    expect(find.text('当前未登录：登录后才能与你的其他设备互联、收发消息和文件。'), findsOneWidget);
    expect(find.text('我的 MacBook Pro'), findsWidgets);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/guest_devices_light.png'));
    await t.tap(find.byTooltip('传输中心'));
    await t.pumpAndSettle();
    expect(find.text('这里会显示所有传输任务'), findsOneWidget);
    await t.tap(find.byTooltip('设置'));
    await t.pumpAndSettle();
    expect(find.text('未登录'), findsWidgets);

    // Sign-in opens as a dialog on demand.
    await t.tap(find.byTooltip('设备会话'));
    await t.pumpAndSettle();
    await t.tap(find.text('登录').first);
    await t.pumpAndSettle();
    expect(find.text('服务器地址'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/login_dialog_light.png'));
    await t.tap(find.byTooltip('关闭'));
    await t.pumpAndSettle();
    expect(find.text('服务器地址'), findsNothing);
  });

  testWidgets('signed out on a phone: lists explain themselves, bottom nav works', (t) async {
    await pumpApp(t, const AppState(), auth: AuthStatus.loggedOut, size: const Size(390, 844));
    expect(find.text('还没有会话'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/guest_narrow_light.png'));
    await t.tap(find.text('设备'));
    await t.pumpAndSettle();
    expect(find.text('我的 MacBook Pro'), findsOneWidget);
    await t.tap(find.text('设置'));
    await t.pumpAndSettle();
    expect(find.text('账号与安全'), findsOneWidget);
  });

  testWidgets('file cards: open / show-in-folder icons for sent files and received files', (t) async {
    await pumpApp(t, fixtureState(), size: const Size(1200, 1300)); // tall enough to build the whole conversation
    // t1 (sent, in progress), t3 is in another chat; in this chat: t1 sent, t4 received+complete, t2 waiting (no file yet).
    expect(find.byTooltip('打开文件'), findsNWidgets(2));
    expect(find.byTooltip('在文件夹中显示'), findsNWidgets(2));
    expect(find.text('显示文件'), findsNothing);
  });

  testWidgets('transfer settings: auto-accept switch is on by default', (t) async {
    await pumpApp(t, fixtureState(section: Section.settings));
    final c = ProviderScope.containerOf(t.element(find.byType(LinkoryApp)));
    await t.tap(find.text('传输').first);
    await t.pumpAndSettle();
    expect(find.textContaining('自动接收'), findsWidgets);
    expect(c.read(storeProvider).autoAccept, isTrue);
  });

  testWidgets('frameless window (Windows/Linux): minimise / maximise / close sit in the page header', (t) async {
    debugShowWindowControls = true;
    addTearDown(() => debugShowWindowControls = false);
    await pumpApp(t, fixtureState());
    expect(find.byTooltip('最小化'), findsOneWidget);
    expect(find.byTooltip('最大化'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/chat_window_controls_light.png'));
    // macOS keeps the native traffic lights, so none of this renders there.
    debugShowWindowControls = false;
    await pumpApp(t, fixtureState());
    expect(find.byTooltip('最小化'), findsNothing);
  });

  testWidgets('composer sends on Enter', (t) async {
    await pumpApp(t, fixtureState());
    await t.enterText(find.byType(TextField).last, 'hello');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    final c = ProviderScope.containerOf(t.element(find.byType(LinkoryApp)));
    expect((c.read(storeProvider.notifier) as FakeStore).sent, ['hello']);
  });

  testWidgets('narrow: single column with bottom nav, detail pages push', (t) async {
    await pumpApp(t, fixtureState(peer: null), size: const Size(390, 844));
    expect(find.text('办公室 Windows'), findsOneWidget);
    expect(find.text('会话'), findsOneWidget); // bottom navigation
    expect(find.byType(TextField), findsOneWidget); // list search only, no chat composer
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/narrow_list_light.png'));

    await t.tap(find.text('办公室 Windows'));
    await t.pumpAndSettle();
    expect(find.text('再发一条试试重试'), findsOneWidget); // newest message: always built, whatever the font metrics
    expect(find.byTooltip('返回'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/narrow_chat_light.png'));

    await t.tap(find.byTooltip('返回'));
    await t.pumpAndSettle();
    expect(find.text('会话'), findsOneWidget);

    await t.tap(find.text('传输'));
    await t.pumpAndSettle();
    expect(find.text('季度报表-final.xlsx'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/narrow_transfers_light.png'));
  });
}
