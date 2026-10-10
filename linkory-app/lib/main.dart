import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/desktop.dart';
import 'core/log.dart';
import 'core/notifications.dart';
import 'core/secrets.dart';
import 'core/session.dart';
import 'core/web/browser.dart';
import 'core/web/fonts.dart';
import 'core/web/web_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Log.init();
  await loadWebFonts();
  await loadWebConfig();
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

  // Notifications: Apple systems and Android use the platform service; Windows / Linux use toast
  // notifications. The desktop part also drives the Dock / launcher badge, window title and tray.
  SystemNotifier notifier = const NoopNotifier();
  final desktopNotifier = desktop == null ? null : DesktopNotifier(desktop, toasts: !Platform.isMacOS); // desktop is null on the web
  if (kIsWeb) {
    notifier = WebNotifier();
    unawaited(browserPersistStorage());
  } else if (MobileMacNotifier.supported) {
    final n = MobileMacNotifier(desktopNotifier);
    await n.init();
    notifier = n;
  } else if (desktopNotifier != null) {
    notifier = desktopNotifier;
  }

  runApp(ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      secretsProvider.overrideWithValue(secrets),
      systemNotifierProvider.overrideWithValue(notifier),
    ],
    child: const LinkoryApp(),
  ));
}
