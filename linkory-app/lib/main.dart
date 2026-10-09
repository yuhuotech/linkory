import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/desktop.dart';
import 'core/log.dart';
import 'core/secrets.dart';
import 'core/session.dart';
import 'core/store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Log.init();
  FlutterError.onError = (d) {
    Log.error('flutter', d.exception, d.stack);
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    Log.error('platform', e, st);
    return true;
  };
  final prefs = await SharedPreferences.getInstance();
  final secrets = await Secrets.load(prefs);
  final desktop = await DesktopShell.init(prefs);
  runApp(ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      secretsProvider.overrideWithValue(secrets),
      if (desktop != null) notifyProvider.overrideWithValue(desktop.notify),
    ],
    child: const LinkoryApp(),
  ));
}
