import 'dart:convert';
import 'dart:io' show Platform;

import 'package:cryptography/cryptography.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'secrets.dart';

const defaultServer = 'http://127.0.0.1:8090';

enum AuthStatus { loading, loggedOut, loggedIn }

class SessionState {
  const SessionState({this.status = AuthStatus.loading, this.serverUrl = defaultServer, this.username = '', this.deviceId = ''});
  final AuthStatus status;
  final String serverUrl, username, deviceId;
  SessionState copyWith({AuthStatus? status, String? serverUrl, String? username, String? deviceId}) => SessionState(
        status: status ?? this.status,
        serverUrl: serverUrl ?? this.serverUrl,
        username: username ?? this.username,
        deviceId: deviceId ?? this.deviceId,
      );
}

final prefsProvider = Provider<SharedPreferences>((_) => throw UnimplementedError('override in main'));

final apiProvider = Provider<ApiClient>((ref) {
  // One client per app; its tokens are mutated by SessionController.
  final s = ref.read(sessionProvider);
  return ApiClient(
    baseUrl: s.serverUrl,
    onTokens: (t) => ref.read(sessionProvider.notifier)._saveTokens(t),
    onAuthLost: () => ref.read(sessionProvider.notifier)._authLost(),
  );
});

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// Owns login state, persisted credentials and this device's identity key.
class SessionController extends Notifier<SessionState> {
  late SharedPreferences _p;
  late Secrets _sec;

  @override
  SessionState build() {
    _p = ref.read(prefsProvider);
    _sec = ref.read(secretsProvider);
    final access = _sec.get('access'), refresh = _sec.get('refresh');
    final loggedIn = access != null && refresh != null && _p.getString('device_id') != null;
    return SessionState(
      status: loggedIn ? AuthStatus.loggedIn : AuthStatus.loggedOut,
      serverUrl: _p.getString('server_url') ?? defaultServer,
      username: _p.getString('username') ?? '',
      deviceId: _p.getString('device_id') ?? '',
    );
  }

  /// Called once after the providers are wired so the API client holds the persisted tokens.
  void restoreTokens(ApiClient api) {
    final a = _sec.get('access'), r = _sec.get('refresh');
    if (a != null && r != null) api.tokens = Tokens(a, r);
  }

  Future<void> register(String server, String username, String password) async {
    final api = ref.read(apiProvider)..baseUrl = _norm(server);
    await api.request('POST', '/auth/register', body: {'username': username, 'password': password}, auth: false);
  }

  Future<void> login(String server, String username, String password) async {
    final api = ref.read(apiProvider)..baseUrl = _norm(server);
    final pub = await _publicKey();
    final j = await api.request('POST', '/auth/login', auth: false, body: {
      'username': username,
      'password': password,
      'device': {
        // Reuse the device identity only for the same server+account; otherwise register anew.
        if (_p.getString('device_server') == api.baseUrl && _p.getString('username') == username)
          'device_id': _p.getString('device_id'),
        'name': await _deviceName(),
        'type': _deviceType(),
        'os_version': _osVersion(),
        'app_version': '0.1.0',
        'public_key': pub,
      },
    });
    api.tokens = Tokens(j['access_token'], j['refresh_token']);
    await _p.setString('server_url', api.baseUrl);
    await _p.setString('device_server', api.baseUrl);
    await _p.setString('username', username);
    await _p.setString('device_id', j['device_id']);
    await _saveTokens(api.tokens!);
    state = state.copyWith(
        status: AuthStatus.loggedIn, serverUrl: api.baseUrl, username: username, deviceId: j['device_id']);
  }

  /// Other devices are signed out by the server; this one keeps its session.
  Future<void> changePassword(String oldPw, String newPw) =>
      ref.read(apiProvider).request('POST', '/auth/password', body: {'old_password': oldPw, 'new_password': newPw});

  Future<void> logout() async {
    final api = ref.read(apiProvider);
    try {
      await api.request('POST', '/auth/logout');
    } catch (_) {}
    _authLost();
  }

  void _authLost() {
    ref.read(apiProvider).tokens = null;
    _sec.remove('access');
    _sec.remove('refresh');
    state = state.copyWith(status: AuthStatus.loggedOut);
  }

  Future<void> _saveTokens(Tokens t) async {
    await _sec.set('access', t.access);
    await _sec.set('refresh', t.refresh);
  }

  String _norm(String s) {
    s = s.trim();
    if (!s.contains('://')) s = 'http://$s';
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  // The identity key never leaves the device; only the public half is registered.
  Future<String> _publicKey() async {
    final alg = Ed25519();
    var seedB64 = _sec.get('key_seed');
    final KeyPair pair;
    if (seedB64 == null) {
      pair = await alg.newKeyPair();
      final seed = await (pair as SimpleKeyPair).extractPrivateKeyBytes();
      await _sec.set('key_seed', base64Encode(seed));
    } else {
      pair = await alg.newKeyPairFromSeed(base64Decode(seedB64));
    }
    final pub = await (pair as SimpleKeyPair).extractPublicKey();
    return base64Encode(pub.bytes);
  }

  String _deviceType() {
    if (kIsWeb) return 'linux';
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => 'linux',
    };
  }

  Future<String> _deviceName() async {
    if (kIsWeb) return 'Web 浏览器';
    try {
      // Phones report "localhost" as hostname; use the model name there.
      if (Platform.isAndroid) {
        final a = await DeviceInfoPlugin().androidInfo;
        final n = '${a.manufacturer} ${a.model}'.trim();
        if (n.isNotEmpty) return n.length > 60 ? n.substring(0, 60) : n;
      } else if (Platform.isIOS) {
        final i = await DeviceInfoPlugin().iosInfo;
        if (i.name.isNotEmpty) return i.name.length > 60 ? i.name.substring(0, 60) : i.name;
      }
      final h = Platform.localHostname;
      return h.length > 60 ? h.substring(0, 60) : h;
    } catch (_) {
      return _deviceType();
    }
  }

  String _osVersion() {
    if (kIsWeb) return 'web';
    try {
      final v = Platform.operatingSystemVersion;
      return v.length > 60 ? '${v.substring(0, 60)}…' : v;
    } catch (_) {
      return '';
    }
  }
}

/// Theme preference: system / light / dark, persisted.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final v = ref.read(prefsProvider).getString('theme_mode');
    return ThemeMode.values.where((m) => m.name == v).firstOrNull ?? ThemeMode.system;
  }

  void set(ThemeMode m) {
    state = m;
    ref.read(prefsProvider).setString('theme_mode', m.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
