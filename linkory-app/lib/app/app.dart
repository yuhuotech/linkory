import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:window_manager/window_manager.dart';

import '../core/desktop.dart';
import '../core/notifications.dart';
import '../core/session.dart';
import '../core/store.dart';
import '../core/updater.dart';
import '../shared/close_dialog.dart';
import '../shared/rounded_window.dart';
import '../features/shell/shell.dart';
import '../theme/tokens.dart';

class LinkoryApp extends ConsumerWidget {
  const LinkoryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(sessionProvider.select((s) => s.status), (_, s) {
      if (s != AuthStatus.loggedIn) ref.read(storeProvider.notifier).stop();
    });
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: '连信 Linkory',
      debugShowCheckedModeBanner: false,
      themeMode: ref.watch(themeModeProvider),
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // Signing in is optional: the full UI is always available, it just is not connected.
      // Frameless window on Linux has no native resize borders: add invisible edge handles.
      builder: (context, child) => (windowShellActive && Platform.isLinux)
          ? DragToResizeArea(child: RoundedWindow(child: child!))
          : child!,
      home: const _Root(),
    );
  }
}

/// The shell is always shown. Once signed in (now or later) it starts the realtime link and data
/// store; signing out stops them and returns to the browse-only state.
class _Root extends ConsumerStatefulWidget {
  const _Root();
  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> with WidgetsBindingObserver {
  late final StoreRef _store = ref.read(storeProvider.notifier);

  void _connect() {
    ref.read(sessionProvider.notifier).restoreTokens(ref.read(apiProvider));
    Future.microtask(_store.start);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phones: "active" means the app is in the foreground. (Desktop windows report focus themselves.)
    if (Platform.isAndroid || Platform.isIOS) ref.read(appActiveProvider.notifier).set(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    onNotificationTap = null;
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Desktop: the window's focus / minimise / hide events decide whether the user is looking at the app.
    DesktopShell.instance?.activeSink = (a) => ref.read(appActiveProvider.notifier).set(a);
    // Clicking a notification brings the window back and opens that conversation.
    onNotificationTap = (peerId) {
      unawaited(DesktopShell.instance?.showWindow());
      unawaited(_store.openConversation(peerId));
    };
    if (ref.read(sessionProvider).status == AuthStatus.loggedIn) _connect();
    // Hourly update check; works signed out too (the first one waits a moment after launch).
    Future.microtask(() => ref.read(updateProvider.notifier).start());
    ref.listenManual(sessionProvider.select((s) => s.status), (prev, s) {
      if (s == AuthStatus.loggedIn && prev != AuthStatus.loggedIn) _connect();
    });
  }

  @override
  Widget build(BuildContext context) => const Shell();
}

typedef StoreRef = AppStore;
