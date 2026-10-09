import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Credentials (tokens, device identity key).
///
/// Signing in must survive restarts, reinstalls and rebuilds. The OS keychain alone cannot promise
/// that: items are bound to the app's code signature on macOS (a rebuilt or re-signed app may no
/// longer read them) and the Linux secret service may be locked or absent. So every value is written
/// to the keychain (best effort) AND to the app's private preferences; reads prefer the keychain and
/// fall back to the preferences copy. Values are only removed on sign-out.
class Secrets {
  Secrets._(this._cache, this._store, this._prefs);

  /// In-memory only (tests).
  factory Secrets.memory([Map<String, String> initial = const {}]) => Secrets._({...initial}, null, null);

  static const keys = ['access', 'refresh', 'key_seed'];

  final Map<String, String> _cache;
  final FlutterSecureStorage? _store;
  final SharedPreferences? _prefs;
  bool _secureOk = true;

  static String _pk(String k) => 'secret_$k';

  static Future<Secrets> load(SharedPreferences prefs) async {
    const store = FlutterSecureStorage();
    final s = Secrets._({}, store, prefs);
    for (final k in keys) {
      String? v;
      try {
        v = await store.read(key: k);
      } catch (e) {
        s._secureOk = false;
        debugPrint('secure storage unavailable, using preferences: $e');
      }
      // Fall back to the preferences copy (also picks up values written by older builds).
      v ??= prefs.getString(_pk(k)) ?? prefs.getString(k);
      if (v != null) {
        s._cache[k] = v;
        // Keep both stores in step (a rebuilt app may have lost keychain access, or the reverse).
        if (s._secureOk) {
          try {
            await store.write(key: k, value: v);
          } catch (_) {
            s._secureOk = false;
          }
        }
        await prefs.setString(_pk(k), v);
        await prefs.remove(k);
      }
    }
    return s;
  }

  String? get(String key) => _cache[key];

  Future<void> set(String key, String value) async {
    _cache[key] = value;
    if (_store == null) return;
    await _prefs?.setString(_pk(key), value); // the copy that always works
    if (_secureOk) {
      try {
        await _store.write(key: key, value: value);
      } catch (_) {
        _secureOk = false;
      }
    }
  }

  Future<void> remove(String key) async {
    _cache.remove(key);
    if (_store == null) return;
    try {
      await _store.delete(key: key);
    } catch (_) {}
    await _prefs?.remove(_pk(key));
    await _prefs?.remove(key);
  }
}

final secretsProvider = Provider<Secrets>((_) => Secrets.memory());
