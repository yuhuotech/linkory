import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web/browser.dart';

/// A browser profile is one device, and the server allows a device a single live connection (the newest wins), so
/// two tabs would keep knocking each other off. Only the tab holding the lock talks to the server; any other tab
/// shows a notice and can take over (WhatsApp Web works the same way). Outside a browser this is always "active".
enum TabState { active, blocked }

class TabGate extends Notifier<TabState> {
  @override
  TabState build() => TabState.active;

  /// Try to become the active tab. [onLost] runs when another tab later takes over.
  Future<bool> acquire({required void Function() onLost}) async {
    final ok = await browserLockAcquire(onLost: () {
      state = TabState.blocked;
      onLost();
    });
    state = ok ? TabState.active : TabState.blocked;
    return ok;
  }

  /// Take the lock from the other tab and reload, so this tab starts from the credentials the other one saved
  /// (refresh tokens rotate; a stale copy would look like a stolen token and sign the account out).
  Future<void> takeOver() async {
    await browserLockAcquire(onLost: () => state = TabState.blocked, steal: true);
    browserReload();
  }
}

final tabGateProvider = NotifierProvider<TabGate, TabState>(TabGate.new);
