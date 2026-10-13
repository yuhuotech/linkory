import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'log.dart';

enum LinkState { connecting, connected, reconnecting, closed }

class WsEvent {
  WsEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

/// WebSocket connection: 30s ping, 90s silence = dead, exponential backoff up to 60s (PRD 4.3).
const _pingEvery = Duration(seconds: 30);
const _watchdogEvery = Duration(seconds: 10);
const _silenceLimit = Duration(seconds: 90); // no frame at all for this long = dead connection

class Realtime {
  Realtime(this.api, {WebSocketChannel Function(Uri, Map<String, String>)? channelFactory, DateTime Function()? now}) : _channelFactory = channelFactory ?? _openChannel, _now = now ?? DateTime.now;
  final ApiClient api;
  final WebSocketChannel Function(Uri, Map<String, String>) _channelFactory;
  final DateTime Function() _now;

  static WebSocketChannel _openChannel(Uri url, Map<String, String> headers) => kIsWeb
      ? WebSocketChannel.connect(url, protocols: ['linkory.v1', 'bearer.${headers['Authorization']?.substring(7) ?? ''}'])
      : IOWebSocketChannel.connect(url, headers: headers, pingInterval: null, connectTimeout: const Duration(seconds: 15));

  final _events = StreamController<WsEvent>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  Stream<WsEvent> get events => _events.stream;
  Stream<LinkState> get stateStream => _state.stream;
  LinkState state = LinkState.closed;

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping, _watchdog, _retry;
  late DateTime _lastRx = _now();
  int _attempt = 0;
  bool _wanted = false;
  bool _connecting = false, _disposed = false;
  int _generation = 0;

  void start() {
    if (_wanted || _disposed) return;
    _wanted = true;
    _attempt = 0;
    _connect();
  }

  void stop() {
    _wanted = false;
    _teardown();
    _set(LinkState.closed);
  }

  void _set(LinkState s) {
    if (_disposed || state == s) return;
    state = s;
    _state.add(s);
  }

  Future<void> _connect() async {
    if (!_wanted || _connecting || _ch != null) return;
    _connecting = true;
    _retry = null;
    final generation = ++_generation;
    _set(_attempt == 0 ? LinkState.connecting : LinkState.reconnecting);
    final base = Uri.parse(api.baseUrl);
    final url = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/api/v1/ws');
    try {
      // Access tokens are short-lived: make sure it is fresh before the handshake.
      await api.request('GET', '/conversations');
      if (!_isCurrent(generation)) return;
      // A browser cannot set headers on a WebSocket: the token goes in the subprotocol list (see PROTOCOL.md).
      final ch = _channelFactory(url, api.authHeaders());
      _ch = ch;
      // Listen before ready: failed handshakes can report both a future and a stream error.
      _sub = ch.stream.listen(
        (raw) {
          if (_isCurrent(generation)) _onFrame(raw);
        },
        onDone: () => _drop(generation, 'socket_closed'),
        onError: (Object e) => _drop(generation, 'socket_error:${e.runtimeType}'),
        cancelOnError: true,
      );
      await ch.ready;
      if (!_isCurrent(generation)) return;
      _attempt = 0;
      _lastRx = _now();
      _set(LinkState.connected);
      _ping = Timer.periodic(_pingEvery, (_) {
        if (_isCurrent(generation)) send('ping', {});
      });
      _watchdog = Timer.periodic(_watchdogEvery, (_) {
        if (_isCurrent(generation) && _now().difference(_lastRx) > _silenceLimit) _drop(generation, 'heartbeat_timeout');
      });
    } catch (e) {
      _drop(generation, 'connect_error:${e.runtimeType}');
    } finally {
      if (_generation == generation) _connecting = false;
    }
  }

  bool _isCurrent(int generation) => _wanted && !_disposed && generation == _generation;

  void _onFrame(dynamic raw) {
    _lastRx = _now();
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      final t = j['type'] as String;
      if (t == 'pong') return;
      _events.add(WsEvent(t, (j['data'] as Map<String, dynamic>?) ?? {}));
    } catch (_) {}
  }

  bool send(String type, Map<String, dynamic> data) {
    if (state != LinkState.connected || _ch == null) return false;
    final frame = jsonEncode({'v': 1, 'type': type, 'ts': _now().millisecondsSinceEpoch, 'data': data});
    try {
      _ch!.sink.add(frame);
      return true;
    } catch (e) {
      _drop(_generation, 'send_error:${e.runtimeType}');
      return false;
    }
  }

  void _teardown() {
    // Invalidate callbacks before closing: sink.close() can synchronously invoke onDone.
    _generation++;
    _connecting = false;
    _ping?.cancel();
    _watchdog?.cancel();
    _retry?.cancel();
    _ping = _watchdog = _retry = null;
    final sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
    final ch = _ch;
    _ch = null;
    if (ch != null) unawaited(_closeChannel(ch));
  }

  static Future<void> _closeChannel(WebSocketChannel ch) async {
    try {
      await ch.sink.close();
    } catch (_) {
      // An already failed connection may also fail while closing.
    }
  }

  void _drop(int generation, String reason) {
    if (!_isCurrent(generation)) return;
    final closeCode = _ch?.closeCode;
    final silenceMs = _now().difference(_lastRx).inMilliseconds;
    _teardown();
    if (!_wanted) return;
    _set(LinkState.reconnecting);
    final secs = min(60, 1 << _attempt);
    _attempt = min(6, _attempt + 1);
    Log.warn('ws', 'disconnected connection=$generation reason=$reason close_code=$closeCode silence_ms=$silenceMs retry_seconds=$secs');
    _retry = Timer(Duration(seconds: secs), _connect);
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    _events.close();
    _state.close();
  }
}
