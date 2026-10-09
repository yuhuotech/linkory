import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'models.dart';
import 'realtime.dart';
import 'session.dart';

enum Section { chats, devices, transfers, settings }

class AppState {
  const AppState({
    this.devices = const [],
    this.online = const {},
    this.selectedPeer,
    this.messages = const {},
    this.transfers = const [],
    this.link = LinkState.closed,
    this.section = Section.chats,
    this.search = '',
    this.error,
    this.saveDir = '',
  });
  final List<Device> devices;
  final Set<String> online;
  final String? selectedPeer;
  final Map<String, List<ChatMessage>> messages;
  final List<Transfer> transfers;
  final LinkState link;
  final Section section;
  final String search;
  final String? error;
  final String saveDir;

  static const _keep = Object();

  AppState copyWith({
    List<Device>? devices,
    Set<String>? online,
    Object? selectedPeer = _keep,
    Map<String, List<ChatMessage>>? messages,
    List<Transfer>? transfers,
    LinkState? link,
    Section? section,
    String? search,
    Object? error = _keep,
    String? saveDir,
  }) =>
      AppState(
        devices: devices ?? this.devices,
        online: online ?? this.online,
        selectedPeer: identical(selectedPeer, _keep) ? this.selectedPeer : selectedPeer as String?,
        messages: messages ?? this.messages,
        transfers: transfers ?? this.transfers,
        link: link ?? this.link,
        section: section ?? this.section,
        search: search ?? this.search,
        error: identical(error, _keep) ? this.error : error as String?,
        saveDir: saveDir ?? this.saveDir,
      );

  Device? device(String id) => devices.where((d) => d.id == id).firstOrNull;
  bool isOnline(String id) => online.contains(id);
  List<Device> get peers => devices.where((d) => !d.current).toList();
  Device? get self => devices.where((d) => d.current).firstOrNull;
}

final realtimeProvider = Provider<Realtime>((ref) {
  final rt = Realtime(ref.read(apiProvider));
  ref.onDispose(rt.dispose);
  return rt;
});

final storeProvider = NotifierProvider<AppStore, AppState>(AppStore.new);

final _rnd = Random.secure();

String newUuid() {
  final r = List<int>.generate(16, (_) => _rnd.nextInt(256));
  r[6] = r[6] & 0x0f | 0x40;
  r[8] = r[8] & 0x3f | 0x80;
  String h(int a, int b) => r.sublist(a, b).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

/// Single source of truth for devices, conversations, messages and file transfers.
class AppStore extends Notifier<AppState> {
  late final ApiClient _api = ref.read(apiProvider);
  late final Realtime _rt = ref.read(realtimeProvider);
  StreamSubscription<WsEvent>? _evSub;
  StreamSubscription<LinkState>? _stSub;
  String get _self => ref.read(sessionProvider).deviceId;

  @override
  AppState build() {
    ref.onDispose(() {
      _evSub?.cancel();
      _stSub?.cancel();
    });
    final p = ref.read(prefsProvider);
    return AppState(saveDir: p.getString('save_dir') ?? _defaultSaveDir());
  }

  String _defaultSaveDir() {
    try {
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
      final s = Platform.pathSeparator;
      return '$home${s}Downloads${s}Linkory';
    } catch (_) {
      return '';
    }
  }

  Future<void> start() async {
    _evSub ??= _rt.events.listen(_onEvent);
    _stSub ??= _rt.stateStream.listen((s) {
      state = state.copyWith(link: s);
      if (s == LinkState.connected) refreshAll();
    });
    _rt.start();
    await refreshAll();
  }

  void stop() {
    _rt.stop();
    state = AppState(saveDir: state.saveDir);
  }

  Future<void> refreshAll() async {
    try {
      await Future.wait([loadDevices(), loadTransfers()]);
      state = state.copyWith(error: null);
    } on ApiException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  Future<void> loadDevices() async {
    final j = await _api.request('GET', '/devices');
    state = state.copyWith(devices: (j['devices'] as List).map((e) => Device.fromJson(e)).toList());
  }

  Future<void> loadTransfers() async {
    final j = await _api.request('GET', '/transfers', query: {'limit': '100'});
    state = state.copyWith(transfers: (j['transfers'] as List).map((e) => Transfer.fromJson(e)).toList());
  }

  void setSection(Section s) => state = state.copyWith(section: s);
  void setSearch(String s) => state = state.copyWith(search: s);
  void clearError() => state = state.copyWith(error: null);

  Future<void> selectPeer(String id) async {
    state = state.copyWith(selectedPeer: id, section: Section.chats);
    await loadHistory(id);
  }

  Future<void> loadHistory(String peer) async {
    try {
      final j = await _api.request('GET', '/messages', query: {'peer_device_id': peer, 'limit': '100'});
      final server = (j['messages'] as List).map((e) => ChatMessage.fromServer(e, _self)).toList().reversed.toList();
      final known = server.map((m) => m.clientId).toSet();
      final pending = (state.messages[peer] ?? [])
          .where((m) => (m.status == MsgStatus.sending || m.status == MsgStatus.failed) && !known.contains(m.clientId));
      _setMsgs(peer, [...server, ...pending]);
    } on ApiException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  void _setMsgs(String peer, List<ChatMessage> list) => state = state.copyWith(messages: {...state.messages, peer: list});

  void _upsert(ChatMessage m) {
    final list = <ChatMessage>[...(state.messages[m.peerId] ?? const <ChatMessage>[])];
    final i = list.indexWhere((x) => x.clientId == m.clientId);
    if (i >= 0) {
      list[i] = m;
    } else {
      list.add(m);
    }
    _setMsgs(m.peerId, list);
  }

  // ---- messaging --------------------------------------------------------------------------

  Future<void> sendText(String peer, String text, {String type = 'text'}) async {
    text = text.trim();
    if (text.isEmpty) return;
    final m = ChatMessage(
        clientId: newUuid(), peerId: peer, mine: true, type: type, content: text, createdAt: DateTime.now(), status: MsgStatus.sending);
    _upsert(m);
    _transmit(m);
  }

  void retry(ChatMessage m) {
    m.status = MsgStatus.sending;
    _upsert(m);
    _transmit(m); // same client_msg_id → the server de-duplicates (MSG-006)
  }

  void _transmit(ChatMessage m) {
    final ok = _rt.send('message.send', {'client_msg_id': m.clientId, 'to_device_id': m.peerId, 'type': m.type, 'content': m.content});
    if (!ok) {
      m.status = MsgStatus.failed;
      _upsert(m);
      return;
    }
    // No ack within 15s → failed; the user can retry safely.
    Future.delayed(const Duration(seconds: 15), () {
      final cur = state.messages[m.peerId]?.where((x) => x.clientId == m.clientId).firstOrNull;
      if (cur != null && cur.status == MsgStatus.sending) {
        cur.status = MsgStatus.failed;
        _upsert(cur);
      }
    });
  }

  void _onEvent(WsEvent e) {
    final d = e.data;
    switch (e.type) {
      case 'presence.snapshot':
        state = state.copyWith(online: {...(d['online_device_ids'] as List? ?? []).cast<String>()});
      case 'device.online':
        state = state.copyWith(online: {...state.online, d['device_id'] as String});
        if (state.device(d['device_id']) == null) loadDevices();
      case 'device.offline':
        state = state.copyWith(online: {...state.online}..remove(d['device_id']));
      case 'message.ack':
        final m = _find(d['client_msg_id']);
        if (m != null) {
          m.id = d['message_id'];
          if (m.status != MsgStatus.delivered) {
            m.status = d['status'] == 'delivered' ? MsgStatus.delivered : MsgStatus.serverReceived;
          }
          _upsert(m);
        }
      case 'message.delivered':
        final m = _find(d['client_msg_id']);
        if (m != null) {
          m.status = MsgStatus.delivered;
          _upsert(m);
        }
      case 'message.receive':
        final m = ChatMessage.fromServer(d, _self);
        _upsert(m);
        _rt.send('message.delivered', {'message_id': m.id}); // stored locally → confirm delivery
        if (state.selectedPeer == null) state = state.copyWith(selectedPeer: m.peerId);
      case 'error':
        state = state.copyWith(error: d['message']?.toString());
      default:
        if (e.type.startsWith('transfer.')) _onTransferEvent(e);
    }
  }

  ChatMessage? _find(String? clientId) {
    for (final l in state.messages.values) {
      for (final m in l) {
        if (m.clientId == clientId) return m;
      }
    }
    return null;
  }

  // ---- file transfers ---------------------------------------------------------------------

  final Map<String, String> _localPaths = {}; // outgoing: task id -> source path
  final Map<String, http.Client> _active = {};

  Future<void> sendFile(String peer, String path) async {
    final f = File(path);
    final size = await f.length();
    final sum = (await crypto.sha256.bind(f.openRead()).first).toString();
    final name = path.split(Platform.pathSeparator).last;
    try {
      final j = await _api.request('POST', '/transfers', body: {'to_device_id': peer, 'file_name': name, 'size': size, 'sha256': sum});
      final t = Transfer.fromJson(j);
      _localPaths[t.id] = path;
      _addTransfer(t);
    } on ApiException catch (e) {
      state = state.copyWith(error: e.code == 'receiver_offline' ? '目标设备不在线，暂不支持离线文件' : e.message);
    }
  }

  void _addTransfer(Transfer t) => state = state.copyWith(transfers: [t, ...state.transfers.where((x) => x.id != t.id)]);

  Transfer? _transfer(String id) => state.transfers.where((t) => t.id == id).firstOrNull;

  void _onTransferEvent(WsEvent e) {
    final d = e.data;
    if (e.type == 'transfer.progress') {
      final t = _transfer(d['id']);
      if (t != null) {
        t.bytes = (d['bytes'] as num).toInt();
        state = state.copyWith(transfers: [...state.transfers]);
      }
      return;
    }
    if (d['id'] == null) return;
    final t = Transfer.fromJson(d);
    t.bytes = _transfer(t.id)?.bytes ?? 0;
    _addTransfer(t);
    if (e.type == 'transfer.accept' && t.sender == _self) _upload(t);
    if (!t.active) _active.remove(t.id)?.close();
  }

  Future<void> accept(Transfer t) async {
    await _api.request('POST', '/transfers/${t.id}/accept');
    unawaited(_download(t));
  }

  Future<void> reject(Transfer t) => _api.request('POST', '/transfers/${t.id}/reject');

  Future<void> cancel(Transfer t) async {
    _active.remove(t.id)?.close();
    try {
      await _api.request('POST', '/transfers/${t.id}/cancel');
    } on ApiException catch (_) {}
  }

  Future<void> _upload(Transfer t) async {
    final path = _localPaths[t.id];
    if (path == null) return;
    final client = http.Client();
    _active[t.id] = client;
    try {
      final req = http.StreamedRequest('PUT', _api.uri('/transfers/${t.id}/data'))
        ..headers.addAll(_api.authHeaders())
        ..headers['Content-Type'] = 'application/octet-stream'
        ..contentLength = t.size;
      File(path).openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError, cancelOnError: true);
      final res = await client.send(req);
      await res.stream.drain<void>();
    } catch (_) {
      // The server marks the task FAILED and notifies both ends; that event updates the UI.
    } finally {
      _active.remove(t.id);
      client.close();
    }
  }

  /// Receiver: write a .part temp file, verify SHA-256, then rename (PRD 4.6 rules).
  Future<void> _download(Transfer t) async {
    final client = http.Client();
    _active[t.id] = client;
    File? part;
    try {
      final dir = Directory(state.saveDir);
      await dir.create(recursive: true);
      part = File('${dir.path}${Platform.pathSeparator}.${t.id}.part');
      final req = http.Request('GET', _api.uri('/transfers/${t.id}/data'))..headers.addAll(_api.authHeaders());
      final res = await client.send(req);
      if (res.statusCode != 200) throw ApiException(res.statusCode, 'download', 'download failed');
      final sink = part.openWrite();
      crypto.Digest? digest;
      final acc = crypto.sha256.startChunkedConversion(_DigestSink((d) => digest = d));
      var n = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        acc.add(chunk);
        n += chunk.length;
      }
      await sink.close();
      acc.close();
      if (n != t.size || digest.toString() != t.sha256) {
        await part.delete();
        await _fail(t, 'checksum mismatch');
        return;
      }
      final target = await _uniqueTarget(dir, t.fileName);
      await part.rename(target.path);
      await _api.request('POST', '/transfers/${t.id}/complete');
    } on FileSystemException catch (e) {
      await _fail(t, e.message.contains('space') ? 'disk full' : 'write error');
      await _tryDelete(part);
    } catch (_) {
      await _tryDelete(part);
    } finally {
      _active.remove(t.id);
      client.close();
    }
  }

  Future<void> _tryDelete(File? f) async {
    try {
      await f?.delete();
    } catch (_) {}
  }

  Future<void> _fail(Transfer t, String reason) async {
    try {
      await _api.request('POST', '/transfers/${t.id}/fail', body: {'reason': reason});
    } on ApiException catch (_) {}
  }

  // Name conflicts never overwrite: "a.txt" -> "a (1).txt".
  Future<File> _uniqueTarget(Directory dir, String name) async {
    final sep = Platform.pathSeparator;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
    var f = File('${dir.path}$sep$name');
    for (var i = 1; await f.exists(); i++) {
      f = File('${dir.path}$sep$stem ($i)$ext');
    }
    return f;
  }

  Future<void> setSaveDir(String dir) async {
    await ref.read(prefsProvider).setString('save_dir', dir);
    state = state.copyWith(saveDir: dir);
  }

  // ---- devices ----------------------------------------------------------------------------

  Future<void> renameDevice(String id, String name) async {
    await _api.request('PATCH', '/devices/$id', body: {'name': name});
    await loadDevices();
  }

  Future<void> removeDevice(String id) async {
    await _api.request('DELETE', '/devices/$id');
    if (state.selectedPeer == id) state = state.copyWith(selectedPeer: null);
    await loadDevices();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  _DigestSink(this.f);
  final void Function(crypto.Digest) f;
  @override
  void add(crypto.Digest d) => f(d);
  @override
  void close() {}
}
