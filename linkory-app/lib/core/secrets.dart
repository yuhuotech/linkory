import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Credentials (tokens, device identity key) live in the OS keychain/credential store.
/// Values are preloaded so reads stay synchronous; writes go through asynchronously.
/// If the keychain is unavailable (e.g. unsigned dev builds) it falls back to SharedPreferences.
class Secrets {
  Secrets._(this._cache, this._store, this._prefs);

  /// In-memory only (tests).
  factory Secrets.memory([Map<String, String> initial = const {}]) => Secrets._({...initial}, null, null);

  static const keys = ['access', 'refresh', 'key_seed'];

  final Map<String, String> _cache;
  final FlutterSecureStorage? _store;
  final SharedPreferences? _prefs;
  bool _secureOk = true;

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
      if (v == null) {
        // Migrate values written by older builds (or the fallback path) out of preferences.
        final old = prefs.getString(k);
        if (old != null) {
          v = old;
          if (s._secureOk) {
            try {
              await store.write(key: k, value: old);
              await prefs.remove(k);
            } catch (_) {
              s._secureOk = false;
            }
          }
        }
      }
      if (v != null) s._cache[k] = v;
    }
    return s;
  }

  String? get(String key) => _cache[key];

  Future<void> set(String key, String value) async {
    _cache[key] = value;
    if (_store == null) return;
    if (_secureOk) {
      try {
        await _store.write(key: key, value: value);
        await _prefs?.remove(key);
        return;
      } catch (_) {
        _secureOk = false;
      }
    }
    await _prefs?.setString(key, value);
  }

  Future<void> remove(String key) async {
    _cache.remove(key);
    if (_store == null) return;
    try {
      await _store.delete(key: key);
    } catch (_) {}
    await _prefs?.remove(key);
  }
}

final secretsProvider = Provider<Secrets>((_) => Secrets.memory());
