import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<ProviderContainer> setup() async {
    SharedPreferences.setMockInitialValues({
      'update_checked_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final prefs = await SharedPreferences.getInstance();
    return ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
  }

  testWidgets('recent check still checks after startup and disabling cancels startup', (t) async {
    final c = await setup();
    addTearDown(c.dispose);
    var calls = 0;
    final n = c.read(updateProvider.notifier);
    http.runWithClient(() => n.start(), () => MockClient((_) async {
      calls++;
      return http.Response(jsonEncode([]), 200);
    }));
    await t.pump(const Duration(seconds: 19));
    expect(calls, 0);
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(c.read(updateProvider).upToDate, isTrue);
    n.start();
    await n.setAutoCheck(false);
    await t.pump(const Duration(minutes: 2));
    expect(calls, 1);
  });

  testWidgets('automatic errors are visible and bounded retries recover', (t) async {
    final c = await setup();
    addTearDown(c.dispose);
    var calls = 0;
    var fail = true;
    final n = c.read(updateProvider.notifier);
    http.runWithClient(() => n.start(firstDelay: Duration.zero), () => MockClient((_) async {
      calls++;
      return http.Response(fail ? 'unavailable' : '[]', fail ? 503 : 200);
    }));
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(c.read(updateProvider).error, contains('503'));
    for (final delay in UpdateNotifier.retryDelays) {
      await t.pump(delay);
      await t.pumpAndSettle();
    }
    expect(calls, 4);
    await t.pump(const Duration(minutes: 1));
    expect(calls, 4);
    fail = false;
    await t.pump(const Duration(minutes: 37)); // hourly cycle at minute 60
    await t.pumpAndSettle();
    expect(calls, 5);
    expect(c.read(updateProvider).error, isNull);
    expect(c.read(updateProvider).upToDate, isTrue);
    await n.setAutoCheck(false);
  });

  testWidgets('turning off auto checks cancels a queued failure retry', (t) async {
    final c = await setup();
    addTearDown(c.dispose);
    var calls = 0;
    final n = c.read(updateProvider.notifier);
    http.runWithClient(() => n.start(firstDelay: Duration.zero), () => MockClient((_) async {
      calls++;
      return http.Response('unavailable', 503);
    }));
    await t.pumpAndSettle();
    expect(calls, 1);
    await n.setAutoCheck(false);
    await t.pump(const Duration(hours: 2));
    expect(calls, 1);
  });
}
