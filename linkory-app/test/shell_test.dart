import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/app/app.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/server_options.dart';
import 'package:linkory_app/core/models.dart' show Transfer, ChatMessage;
import 'package:linkory_app/theme/tokens.dart';
import 'package:linkory_app/core/store.dart';
import 'package:linkory_app/features/transfers/transfer_card.dart' show ImagePreview;
import 'package:linkory_app/core/updater.dart';
import 'package:linkory_app/core/update_install.dart';
import 'package:linkory_app/shared/widgets.dart' show debugShowWindowControls, HoverRow;

import 'support.dart';

Future<void> pumpApp(WidgetTester t, AppState s,
    {Brightness b = Brightness.light, AuthStatus auth = AuthStatus.loggedIn, Size size = const Size(1200, 780), UpdateState? update, List<OfficialServer> servers = const []}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.platformBrightnessTestValue = b;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
  await t.pumpWidget(ProviderScope(key: UniqueKey(), overrides: [...await overrides(s, auth: auth, update: update), officialServersProvider.overrideWithValue(servers)], child: const LinkoryApp()));
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

  testWidgets('logo returns to the signed-in home and quick actions work', (t) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await pumpApp(t, fixtureState(), b: brightness);
      await t.tap(find.byTooltip('返回首页'));
      await t.pumpAndSettle();
      expect(find.text('欢迎回来，hongmw'), findsOneWidget);
      expect(find.text('已连接'), findsOneWidget);
      expect(find.text('2 台在线 / 3 台已关联'), findsOneWidget);
      expect(find.text('注册账号'), findsNothing);
      final theme = brightness == Brightness.light ? 'light' : 'dark';
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/home_signed_in_$theme.png'));
      await t.tap(find.text('发送消息'));
      await t.pumpAndSettle();
      expect(find.text('欢迎回来，hongmw'), findsNothing);
      expect(find.text('文件我放在共享盘了，你看一下'), findsOneWidget);
      await t.tap(find.byTooltip('返回首页'));
      await t.pumpAndSettle();
      await t.tap(find.text('传输中心'));
      await t.pumpAndSettle();
      expect(find.text('欢迎回来，hongmw'), findsNothing);
      await t.tap(find.byTooltip('返回首页'));
      await t.pumpAndSettle();
      expect(find.text('欢迎回来，hongmw'), findsOneWidget);
    }
    await pumpApp(t, const AppState());
    await t.tap(find.byTooltip('设备会话'));
    await t.pumpAndSettle();
    expect(find.text('欢迎回来，hongmw'), findsNothing);
    expect(find.text('选择一台设备开始会话'), findsOneWidget);
    await t.tap(find.byTooltip('返回首页'));
    await t.pumpAndSettle();
    expect(find.text('在另一台设备上登录同一账号，即可开始互发消息和文件。'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('unselected device rows retain hover until pointer leaves', (t) async {
    for (final section in [Section.chats, Section.devices]) {
      await pumpApp(t, fixtureState(section: section));
      final row = find.ancestor(of: find.text('Pixel 9'), matching: find.byType(HoverRow));
      final pointer = await t.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: const Offset(1190, 770));
      await pointer.moveTo(t.getCenter(row));
      await t.pumpAndSettle();
      Color? background() => (t.widget<DecoratedBox>(find.descendant(
        of: row, matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration).color;
      final hover = background();
      expect(hover, isNot(Colors.transparent));
      await t.pump(const Duration(seconds: 1));
      expect(background(), hover);
      await pointer.moveTo(t.getTopLeft(row) + const Offset(12, 12));
      await t.pumpAndSettle();
      expect(background(), hover);
      await pointer.moveTo(const Offset(1190, 770));
      await t.pumpAndSettle();
      expect(background(), Colors.transparent);
      await pointer.removePointer();
    }
  });

  testWidgets('device details open a peer conversation and exclude this device', (t) async {
    await pumpApp(t, fixtureState(section: Section.devices));
    expect(find.text('发消息'), findsNothing);
    await t.tap(find.text('Pixel 9').first);
    await t.pumpAndSettle();
    expect(find.text('发消息'), findsOneWidget);
    await t.tap(find.text('发消息'));
    await t.pumpAndSettle();
    expect(find.text('发消息'), findsNothing);
    expect(find.byTooltip('发送剪贴板文本'), findsOneWidget);
    await t.tap(find.byTooltip('设备管理'));
    await t.pumpAndSettle();
    await t.tap(find.text('Ubuntu 工作站').first);
    await t.pumpAndSettle();
    expect(find.text('发消息'), findsOneWidget);
    await t.tap(find.text('发消息'));
    await t.pumpAndSettle();
    expect(find.byTooltip('发送剪贴板文本'), findsOneWidget);
    expect(t.takeException(), isNull);

    await pumpApp(t, fixtureState(section: Section.devices), size: const Size(390, 844));
    await t.tap(find.text('Pixel 9').first);
    await t.pumpAndSettle();
    await t.tap(find.text('发消息'));
    await t.pumpAndSettle();
    expect(find.byTooltip('发送剪贴板文本'), findsOneWidget);
    expect(find.text('发消息'), findsNothing);
    await t.tap(find.byTooltip('返回'));
    await t.pumpAndSettle();
    expect(find.byTooltip('发送剪贴板文本'), findsNothing);
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('received Chinese clipboard keeps content and CJK font fallback', (t) async {
    final state = fixtureState();
    await pumpApp(t, state.copyWith(messages: {
      'win': [ChatMessage(clientId: 'chinese-clipboard', peerId: 'win', mine: false,
        type: 'clipboard', content: '现在本地领先', createdAt: DateTime(2026, 10, 10))],
    }));
    final text = t.widget<Text>(find.text('现在本地领先'));
    expect(text.style!.fontFamilyFallback, contains('NotoSansSC'));
    expect(text.style!.fontFamilyFallback, contains('PingFang SC'));
    expect(text.style!.fontFamilyFallback, contains('Consolas'));
    expect(text.style!.fontFamilyFallback, Type.monoFallback);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/clipboard_chinese_light.png'));
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
    expect(find.text('局域网 IP'), findsOneWidget);
    expect(find.text('192.168.1.23'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/guest_devices_light.png'));
    await t.tap(find.byTooltip('传输中心'));
    await t.pumpAndSettle();
    expect(find.text('这里会显示所有传输任务'), findsOneWidget);
    await t.tap(find.byTooltip('设置'));
    await t.pumpAndSettle();
    expect(find.text('未登录'), findsWidgets);

    // Sign-in opens as a dialog on demand.
    await t.tap(find.byTooltip('返回首页'));
    await t.pumpAndSettle();
    await t.tap(find.text('登录').first);
    await t.pumpAndSettle();
    expect(find.text('服务器地址'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/login_dialog_light.png'));
    await t.tap(find.byTooltip('关闭'));
    await t.pumpAndSettle();
    expect(find.text('服务器地址'), findsNothing);
  });

  testWidgets('auth actions switch modes in light and dark themes', (t) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await pumpApp(t, const AppState(), auth: AuthStatus.loggedOut, b: brightness);
      await t.tap(find.text('登录').first);
      await t.pumpAndSettle();
      final theme = brightness == Brightness.light ? 'light' : 'dark';
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/login_dialog_$theme.png'));
      await t.tap(find.text('注册账号').last);
      await t.pumpAndSettle();
      expect(find.text('注册并登录'), findsOneWidget);
      expect(find.text('确认密码'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/register_dialog_$theme.png'));
      await t.tap(find.text('注册并登录'));
      await t.pumpAndSettle();
      expect(find.text('请再次输入密码'), findsWidgets);
      await t.enterText(find.widgetWithText(TextField, '至少 8 位'), 'password123');
      await t.enterText(find.widgetWithText(TextField, '请再次输入密码'), 'different123');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(find.text('两次输入的密码不一致，请重新确认'), findsOneWidget);
      await t.tap(find.text('返回登录'));
      await t.pumpAndSettle();
      expect(find.text('注册并登录'), findsNothing);
      expect(find.text('确认密码'), findsNothing);
      await t.tap(find.byTooltip('关闭'));
      await t.pumpAndSettle();
    }
  });

  testWidgets('server selection separates official service and custom address', (t) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await pumpApp(t, const AppState(), auth: AuthStatus.loggedOut, b: brightness,
        size: const Size(390, 844), servers: const [
          OfficialServer(name: '连信官方', url: 'https://linkory.dev99.cn'),
        ]);
      await t.tap(find.text('登录').first);
      await t.pumpAndSettle();
      expect(find.text('连信官方'), findsOneWidget);
      expect(find.text('服务器地址'), findsNothing);
      final theme = brightness == Brightness.light ? 'light' : 'dark';
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/login_official_$theme.png'));
      final selector = find.widgetWithText(TextButton, '连信官方');
      final selectorBottom = t.getBottomLeft(selector).dy;
      await t.tap(find.text('连信官方'));
      await t.pumpAndSettle();
      final customOption = find.widgetWithText(MenuItemButton, '自建服务器');
      expect(t.getTopLeft(customOption).dy, greaterThan(selectorBottom));
      expect(t.getSize(customOption).height, 32);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/server_menu_$theme.png'));
      await t.tap(find.text('自建服务器').last);
      await t.pumpAndSettle();
      expect(find.text('服务器地址'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'https://linkory.example.com'), 'not-a-url');
      await t.tap(find.text('登录').last);
      await t.pumpAndSettle();
      expect(find.text('请输入完整的服务器地址，例如 https://linkory.example.com'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'https://linkory.example.com'), 'https://my-server.example.com:8443');
      await t.tap(find.text('自建服务器'));
      await t.pumpAndSettle();
      await t.tap(find.text('连信官方').last);
      await t.pumpAndSettle();
      expect(find.text('服务器地址'), findsNothing);
      expect(find.text('请输入完整的服务器地址，例如 https://linkory.example.com'), findsNothing);
      await t.tap(find.text('连信官方'));
      await t.pumpAndSettle();
      await t.tap(find.text('自建服务器').last);
      await t.pumpAndSettle();
      expect(find.text('https://my-server.example.com:8443'), findsOneWidget);
      await t.tap(find.text('注册账号').last);
      await t.pumpAndSettle();
      expect(find.text('确认密码'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/register_custom_phone_$theme.png'));
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('关闭'));
      await t.pumpAndSettle();
    }
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
    await t.tap(find.text('网络传输').first);
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

  UpdateState available({String? manualReason}) {
    final info = UpdateInfo(
      version: SemVer.tryParse('0.2.0')!,
      tag: 'v0.2.0',
      notes: "## 下载\n| 平台 | 安装包 |\n\n## 更新内容\n### 体验优化\n- **会话排版改版**，历史消息更清晰\n- 新增软件更新，支持 `签名校验`\n- [查看完整更新记录](https://github.com/yuhuotech/linkory/releases)\n\n## 自建服务端\n部署说明",
      pageUrl: 'https://github.com/yuhuotech/linkory/releases/tag/v0.2.0',
      prerelease: false,
      publishedAt: DateTime(2025, 3, 14, 9, 0),
      assets: const [],
    );
    return UpdateState(latest: info, lastChecked: DateTime(2025, 3, 14, 10, 0), install: manualReason == null ? InstallPlan.fake('Linkory-0.2.0-macos.zip') : InstallPlan.fakeManual(manualReason));
  }

  testWidgets('update available: arrow above the settings button opens the dialog', (t) async {
    await pumpApp(t, fixtureState(), update: available());
    expect(find.byTooltip('发现新版本 0.2.0，点击查看并更新'), findsOneWidget);
    await t.tap(find.byTooltip('发现新版本 0.2.0，点击查看并更新'));
    await t.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('0.2.0'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('前往下载页'), findsOneWidget);
    expect(find.textContaining('新增软件更新'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/update_dialog_light.png'));
    expect(find.text('体验优化'), findsOneWidget);
    expect(find.text('部署说明'), findsNothing);
    await t.tap(find.byTooltip('关闭'));
    await t.pumpAndSettle();
    await pumpApp(t, fixtureState(), b: Brightness.dark, update: available());
    await t.tap(find.byTooltip('发现新版本 0.2.0，点击查看并更新'));
    await t.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/update_dialog_dark.png'));
  });

  testWidgets('update available but this install cannot self-update: only the download page is offered', (t) async {
    await pumpApp(t, fixtureState(), update: available(manualReason: '请先把应用拖到「应用程序」文件夹，再使用自动更新'));
    await t.tap(find.byTooltip('发现新版本 0.2.0，点击查看并更新'));
    await t.pumpAndSettle();
    expect(find.text('立即更新'), findsNothing);
    expect(find.text('前往下载页'), findsOneWidget);
    expect(find.textContaining('拖到「应用程序」'), findsOneWidget);
  });

  testWidgets('no update: no arrow; settings has a 软件更新 page', (t) async {
    await pumpApp(t, fixtureState(section: Section.settings));
    expect(find.textContaining('发现新版本'), findsNothing);
    await t.tap(find.text('软件更新'));
    await t.pumpAndSettle();
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('自动检查'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/settings_update_light.png'));
  });

  testWidgets('image files show an inline preview; clicking it opens the viewer, Esc closes', (t) async {
    // A real 64x40 PNG on disk.
    late String path;
    await t.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 64, 40), Paint()..color = const Color(0xFF3B82F6));
      final img = await rec.endRecording().toImage(64, 40);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
      final f = File('${Directory.systemTemp.path}/linkory_test_pic_${DateTime.now().microsecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes.buffer.asUint8List());
      path = f.path;
    });
    addTearDown(() {
      if (File(path).existsSync()) File(path).deleteSync();
    });
    FakeStore.files['pic'] = path;
    addTearDown(FakeStore.files.clear);
    final base = fixtureState();
    final withPic = base.copyWith(transfers: [
      ...base.transfers,
      Transfer(id: 'pic', sender: 'mac', receiver: 'win', fileName: '风景.png', size: 1234, sha256: 'x', status: 'COMPLETED', createdAt: DateTime(2025, 3, 14, 10, 29)),
    ]);
    await pumpApp(t, withPic, size: const Size(1200, 1300));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150))); // the existence probe is real I/O
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImagePreview), findsOneWidget);
    expect(find.text('风景.png'), findsOneWidget);

    await t.tap(find.byType(ImagePreview));
    await t.pumpAndSettle();
    expect(find.text('风景.png'), findsNWidgets(2)); // the card + the viewer's title
    expect(find.byTooltip('关闭（Esc）'), findsOneWidget);
    expect(find.byTooltip('用系统程序打开原图'), findsOneWidget);

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byTooltip('关闭（Esc）'), findsNothing);

    // A single click closes right away: well inside the old ~300ms double-tap wait.
    await t.tap(find.byType(ImagePreview));
    await t.pumpAndSettle();
    expect(find.byTooltip('关闭（Esc）'), findsOneWidget);
    await t.tapAt(const Offset(600, 500));
    await t.pump(); // the tap is delivered and the 90ms fade-out starts
    await t.pump(const Duration(milliseconds: 120));
    expect(find.byTooltip('关闭（Esc）'), findsNothing, reason: 'closing must not wait for a possible double-click');

    // A file that no longer exists shows no preview (and no broken-image box).
    File(path).deleteSync();
    FakeStore.files['pic'] = '${path}_gone';
    await pumpApp(t, withPic, size: const Size(1200, 1300));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImagePreview), findsOneWidget);
    expect(find.descendant(of: find.byType(ImagePreview), matching: find.byType(Image)), findsNothing);
  });

  testWidgets('unread: badge on the conversation row, count on the rail, banner for a message in another conversation', (t) async {
    final base = fixtureState(peer: 'win');
    await pumpApp(t, base.copyWith(unread: const {'phone': 3, 'lnx': 120}));
    expect(find.text('3'), findsWidgets); // row badge for Pixel 9
    expect(find.text('99+'), findsNWidgets(2), reason: 'counts are capped (row badge and rail badge)');
    expect(find.byTooltip('设备会话（123 条未读）'), findsOneWidget, reason: 'rail shows the total');

    final c = ProviderScope.containerOf(t.element(find.byType(LinkoryApp)));
    c.read(toastProvider.notifier).show('phone', 'Pixel 9', '到家了，文件发你了', 3);
    await t.pump(); // the banner's fade-in starts on this frame…
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('到家了，文件发你了'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/unread_light.png'));

    // Clicking the banner opens that conversation and the banner goes away.
    await t.tap(find.text('到家了，文件发你了'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('到家了，文件发你了'), findsNothing);
    c.read(toastProvider.notifier).dismiss();
    await t.pump(const Duration(seconds: 6)); // flush the banner's auto-dismiss timer
  });
}
