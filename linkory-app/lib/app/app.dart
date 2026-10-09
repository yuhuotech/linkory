import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import '../core/store.dart';
import '../features/auth/login_page.dart';
import '../features/shell/shell.dart';
import '../theme/tokens.dart';

class LinkoryApp extends ConsumerWidget {
  const LinkoryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(sessionProvider.select((s) => s.status));
    ref.listen(sessionProvider.select((s) => s.status), (_, s) {
      if (s != AuthStatus.loggedIn) ref.read(storeProvider.notifier).stop();
    });
    return MaterialApp(
      title: '连信 Linkory',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: switch (auth) {
        AuthStatus.loggedIn => const _Authed(),
        _ => const LoginPage(),
      },
    );
  }
}

/// Starts the realtime link + data store once logged in; stops them on logout.
class _Authed extends ConsumerStatefulWidget {
  const _Authed();
  @override
  ConsumerState<_Authed> createState() => _AuthedState();
}

class _AuthedState extends ConsumerState<_Authed> {
  late final StoreRef _store = ref.read(storeProvider.notifier);

  @override
  void initState() {
    super.initState();
    ref.read(sessionProvider.notifier).restoreTokens(ref.read(apiProvider));
    Future.microtask(_store.start);
  }

  @override
  Widget build(BuildContext context) => const Shell();
}

typedef StoreRef = AppStore;
