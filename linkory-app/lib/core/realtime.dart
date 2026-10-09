import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';

enum LinkState { connecting, connected, reconnecting, closed }

class WsEvent {
  WsEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

/// WebSocket connection: 30s ping, 90s silence = dead, exponential backoff up to 60s (PRD 4.3).
class Realtime {
  Realtime(this.api);
  final ApiClient api;

  final _events = StreamController<WsEvent>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  Stream<WsEvent> get events => _events.stream;
  Stream<LinkState> get stateStream => _state.stream;
  LinkState state = LinkState.closed;

  WebSocketChannel? _ch;
  Timer? _ping, _watchdog, _retry;
  DateTime _lastRx = DateTime.now();
  int _attempt = 0;
  bool _wanted = false;

  void start() {
    _wanted = true;
    _connect();
  }

  void stop() {
    _wanted = false;
    _teardown();
    _set(LinkState.closed);
  }

  void _set(LinkState s) {
    state = s;
    _state.add(s);
  }

  Future<void> _connect() async {
    if (!_wanted) return;
    _set(_attempt == 0 ? LinkState.connecting : LinkState.reconnecting);
    final base = Uri.parse(api.baseUrl);
    final url = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/api/v1/ws');
    try {
      // Access tokens are short-lived: make sure it is fresh before the handshake.
      await api.request('GET', '/conversations');
      final ch = IOWebSocketChannel.connect(url, headers: api.authHeaders(), pingInterval: null);
      _ch = ch;
      await ch.ready;
      _attempt = 0;
      _lastRx = DateTime.now();
      _set(LinkState.connected);
      _ping = Timer.periodic(const Duration(seconds: 30), (_) => send('ping', {}));
      _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        if (DateTime.now().difference(_lastRx) > const Duration(seconds: 90)) _drop();
      });
      ch.stream.listen(_onFrame, onDone: _drop, onError: (_) => _drop(), cancelOnError: true);
    } catch (_) {
      _drop();
    }
  }

  void _onFrame(dynamic raw) {
    _lastRx = DateTime.now();
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      final t = j['type'] as String;
      if (t == 'pong') return;
      _events.add(WsEvent(t, (j['data'] as Map<String, dynamic>?) ?? {}));
    } catch (_) {}
  }

  bool send(String type, Map<String, dynamic> data) {
    if (state != LinkState.connected || _ch == null) return false;
    _ch!.sink.add(jsonEncode({'v': 1, 'type': type, 'ts': DateTime.now().millisecondsSinceEpoch, 'data': data}));
    return true;
  }

  void _teardown() {
    _ping?.cancel();
    _watchdog?.cancel();
    _retry?.cancel();
    _ch?.sink.close();
    _ch = null;
  }

  void _drop() {
    if (_retry?.isActive == true) return;
    _teardown();
    if (!_wanted) return;
    _set(LinkState.reconnecting);
    final secs = min(60, pow(2, _attempt).toInt());
    _attempt++;
    _retry = Timer(Duration(seconds: secs), _connect);
  }

  void dispose() {
    stop();
    _events.close();
    _state.close();
  }
}
