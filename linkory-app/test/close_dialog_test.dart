import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/shared/close_dialog.dart';
import 'package:linkory_app/theme/tokens.dart';

import 'support.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('first close: hide-to-tray is preselected', (t) async {
    t.view.physicalSize = const Size(700, 520);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(builder: (ctx) => TextButton(onPressed: () => showCloseDialog(ctx, trayAvailable: true), child: const Text('close'))),
    ));
    await t.tap(find.text('close'));
    await t.pumpAndSettle();
    expect(find.text('关闭连信'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/close_dialog_light.png'));
  });

  testWidgets('result carries the default choice (tray + remember)', (t) async {
    CloseChoice? got;
    t.view.physicalSize = const Size(700, 520);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (ctx) => TextButton(onPressed: () async => got = await showCloseDialog(ctx, trayAvailable: true), child: const Text('close')),
      ),
    ));
    await t.tap(find.text('close'));
    await t.pumpAndSettle();
    await t.tap(find.text('确定'));
    await t.pumpAndSettle();
    expect(got?.toTray, isTrue);
    expect(got?.remember, isTrue);

    // Choosing quit and unticking "remember".
    await t.tap(find.text('close'));
    await t.pumpAndSettle();
    await t.tap(find.text('退出应用'));
    await t.tap(find.textContaining('记住我的选择'));
    await t.tap(find.text('确定'));
    await t.pumpAndSettle();
    expect(got?.toTray, isFalse);
    expect(got?.remember, isFalse);

    // Cancel keeps the window open (null).
    got = const CloseChoice(toTray: true, remember: true);
    await t.tap(find.text('close'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(got, isNull);
  });

  testWidgets('no tray support (e.g. GNOME without AppIndicator): hide option is disabled, default is quit', (t) async {
    CloseChoice? got;
    t.view.physicalSize = const Size(700, 520);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (ctx) => TextButton(onPressed: () async => got = await showCloseDialog(ctx, trayAvailable: false), child: const Text('close')),
      ),
    ));
    await t.tap(find.text('close'));
    await t.pumpAndSettle();
    expect(find.textContaining('没有托盘支持'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/close_dialog_no_tray_light.png'));
    await t.tap(find.text('隐藏到托盘')); // disabled: ignored
    await t.tap(find.text('确定'));
    await t.pumpAndSettle();
    expect(got?.toTray, isFalse);
  });
}
