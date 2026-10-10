import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'lan/lan.dart';
import 'log.dart';
import 'notifications.dart';
import '../shared/format.dart';
import 'models.dart';
import 'realtime.dart';
import 'session.dart';

enum Section { chats, devices, transfers, settings }

/// File transfer needs the local file system (browser edition: not yet).
const canTransferFiles = !kIsWeb;

class AppState {
  const AppState({
    this.devices = const [],
    this.online = const {},
    this.selectedPeer,
    this.showingHome = true,
    this.messages = const {},
    this.transfers = const [],
    this.link = LinkState.closed,
    this.section = Section.chats,
    this.search = '',
    this.error,
    this.saveDir = '',
    this.transferMode = 'auto',
    this.autoAccept = true,
    this.unread = const {},
    this.notifyEnabled = true,
    this.notifyPreview = true,
  });
  final List<Device> devices;
  final Set<String> online;
  final String? selectedPeer;
  final bool showingHome;
  final Map<String, List<ChatMessage>> messages;
  final List<Transfer> transfers;
  final LinkState link;
  final Section section;
  final String search;
  final String? error;
  final String saveDir;

  /// auto = try same-network direct first, relay otherwise; lan = direct only; relay = server relay only.
  final String transferMode;

  /// Accept incoming files without asking (default). Offers only come from your own devices.
  final bool autoAccept;

  /// Unread messages / incoming files per conversation (peer device id → count), persisted.
  final Map<String, int> unread;

  /// Raise notifications for new messages; and whether they show the content (privacy).
  final bool notifyEnabled, notifyPreview;
  int get totalUnread => unread.values.fold(0, (a, b) => a + b);

  static const _keep = Object();

  AppState copyWith({
    List<Device>? devices,
    Set<String>? online,
    Object? selectedPeer = _keep,
    bool? showingHome,
    Map<String, List<ChatMessage>>? messages,
    List<Transfer>? transfers,
    LinkState? link,
    Section? section,
    String? search,
    Object? error = _keep,
    String? saveDir,
    String? transferMode,
    bool? autoAccept,
    Map<String, int>? unread,
    bool? notifyEnabled,
    bool? notifyPreview,
  }) =>
      AppState(
        devices: devices ?? this.devices,
        online: online ?? this.online,
        selectedPeer: identical(selectedPeer, _keep) ? this.selectedPeer : selectedPeer as String?,
        showingHome: showingHome ?? this.showingHome,
        messages: messages ?? this.messages,
        transfers: transfers ?? this.transfers,
        link: link ?? this.link,
        section: section ?? this.section,
        search: search ?? this.search,
        error: identical(error, _keep) ? this.error : error as String?,
        saveDir: saveDir ?? this.saveDir,
        transferMode: transferMode ?? this.transferMode,
        autoAccept: autoAccept ?? this.autoAccept,
        unread: unread ?? this.unread,
        notifyEnabled: notifyEnabled ?? this.notifyEnabled,
        notifyPreview: notifyPreview ?? this.notifyPreview,
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

/// A short in-app banner for a message that arrives while another conversation is open.
class Toast {
  const Toast({required this.id, required this.peerId, required this.title, required this.body, required this.count});
  final int id, count;
  final String peerId, title, body;
}

class ToastNotifier extends Notifier<Toast?> {
  Timer? _t;
  int _n = 0;
  @override
  Toast? build() {
    ref.onDispose(() => _t?.cancel());
    return null;
  }

  void show(String peerId, String title, String body, int count) {
    _t?.cancel();
    state = Toast(id: ++_n, peerId: peerId, title: title, body: body, count: count);
    _t = Timer(const Duration(seconds: 5), dismiss);
  }

  void dismiss() {
    _t?.cancel();
    if (state != null) state = null;
  }
}

final toastProvider = NotifierProvider<ToastNotifier, Toast?>(ToastNotifier.new);

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
    _savedPaths = _loadMap(p.getString('saved_paths'));
    _localPaths.addAll(_loadMap(p.getString('send_paths')));
    _hiddenMsgs = (p.getStringList('hidden_msgs') ?? const []).toSet();
    _hiddenTasks = (p.getStringList('hidden_tasks') ?? const []).toSet();
    // Becoming active again while a conversation is on screen reads it.
    ref.listen(appActiveProvider, (_, active) {
      if (active) _readVisible();
    });
    return AppState(
      saveDir: p.getString('save_dir') ?? _defaultSaveDir(),
      transferMode: p.getString('transfer_mode') ?? 'auto',
      autoAccept: p.getBool('auto_accept') ?? true,
      unread: _loadCounts(p.getString('unread_counts')),
      notifyEnabled: p.getBool('notify_enabled') ?? true,
      notifyPreview: p.getBool('notify_preview') ?? true,
    );
  }

  static Map<String, int> _loadCounts(String? raw) {
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  late Map<String, String> _savedPaths; // receiver: task id -> saved file path
  late Set<String> _hiddenMsgs, _hiddenTasks; // locally deleted records (server history is kept)

  static Map<String, String> _loadMap(String? raw) {
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _persist() async {
    final p = ref.read(prefsProvider);
    await p.setString('saved_paths', jsonEncode(_savedPaths));
    await p.setString('send_paths', jsonEncode(_localPaths));
    await p.setStringList('hidden_msgs', _hiddenMsgs.toList());
    await p.setStringList('hidden_tasks', _hiddenTasks.toList());
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
    lanLog = (m) => Log.info('lan', m);
    _evSub ??= _rt.events.listen(_onEvent);
    _stSub ??= _rt.stateStream.listen((s) {
      state = state.copyWith(link: s);
      Log.info('ws', s.name);
      if (s == LinkState.connected) {
        refreshAll();
        unawaited(_reportLan());
      }
    });
    _rt.start();
    unawaited(ref.read(systemNotifierProvider).setUnread(state.totalUnread));
    await refreshAll();
    await _startLan();
  }

  // ---- same-network direct transfer -------------------------------------------------------

  LanListener? _lan;
  Timer? _lanTimer;
  String _lastReport = '';
  final Set<String> _lanAccepted = {}; // tasks this device accepted: the only ones the listener serves
  final Set<String> _lanBusy = {}; // tasks with a live direct session
  final Set<String> _lanDone = {};

  Future<void> _startLan() async {
    if (_lan != null || kIsWeb || state.transferMode == 'relay') return;
    try {
      _lan = await LanListener.bind(_lanHooks());
      Log.info('lan', 'listening on ${_lan!.port}');
      await _reportLan();
      _lanTimer?.cancel();
      _lanTimer = Timer.periodic(const Duration(seconds: 60), (_) => _reportLan()); // network changes
    } catch (e) {
      Log.warn('lan', 'listener unavailable: ${e.runtimeType}');
    }
  }

  Future<void> _reportLan({bool force = false}) async {
    final l = _lan;
    if (l == null || state.link != LinkState.connected) return;
    final addrs = await localLanAddresses();
    if (addrs.isEmpty) return;
    final key = '${addrs.join(',')}:${l.port}';
    if (!force && key == _lastReport) return;
    if (_rt.send('lan.report', {'addrs': addrs, 'port': l.port})) _lastReport = key;
  }

  LanHooks _lanHooks() => LanHooks(
        lookup: (id) {
          final t = _transfer(id);
          if (t == null || t.receiver != _self || t.lanSecret.isEmpty || !_lanAccepted.contains(id)) return null;
          if (t.status != 'ACCEPTED' && t.status != 'TRANSFERRING') return null;
          return LanIncoming(
              taskId: id,
              secret: hexToBytes(t.lanSecret),
              size: t.size,
              sha256: t.sha256,
              part: File('${state.saveDir}${Platform.pathSeparator}.$id.lan.part'));
        },
        onStart: (id) {
          _lanBusy.add(id);
          _active.remove(id)?.close(); // the sender will not use the relay while the direct path works
          _transfer(id)?.mode = 'lan';
          unawaited(_api.request('POST', '/transfers/$id/lan/start').then((_) {}, onError: (_) {}));
          Log.info('lan', 'direct session started');
        },
        onProgress: _applyProgress,
        onVerified: (id, part) async {
          final t = _transfer(id);
          if (t == null) return false;
          try {
            final target = await _uniqueTarget(Directory(state.saveDir), t.fileName);
            await part.rename(target.path);
            _savedPaths[id] = target.path;
            t.savedPath = target.path;
            _lanDone.add(id);
            unawaited(_persist());
            await _api.request('POST', '/transfers/$id/complete', body: {'via': 'lan'});
            return true;
          } catch (e) {
            Log.warn('lan', 'finalize failed: ${e.runtimeType}');
            return false;
          }
        },
        onFailed: (id, {required corrupt}) {
          _lanBusy.remove(id);
          final t = _transfer(id);
          if (t == null || !t.active || _lanDone.contains(id)) return;
          Log.warn('lan', 'direct session ended (corrupt=$corrupt)');
          if (state.transferMode == 'lan') {
            unawaited(_fail(t, 'direct transfer failed'));
            return;
          }
          // Give the sender a moment to reconnect and resume; otherwise pull through the relay.
          Future.delayed(Duration(seconds: corrupt ? 0 : 5), () {
            final cur = _transfer(id);
            if (cur != null && cur.active && !_lanBusy.contains(id) && !_active.containsKey(id)) unawaited(_download(cur));
          });
        },
      );

  Future<void> setAutoAccept(bool on) async {
    await ref.read(prefsProvider).setBool('auto_accept', on);
    state = state.copyWith(autoAccept: on);
  }

  Future<void> setTransferMode(String mode) async {
    await ref.read(prefsProvider).setString('transfer_mode', mode);
    state = state.copyWith(transferMode: mode);
    if (mode == 'relay') {
      _lanTimer?.cancel();
      await _lan?.close();
      _lan = null;
      _lastReport = '';
    } else {
      await _startLan();
    }
  }

  void stop() {
    _rt.stop();
    _lanTimer?.cancel();
    unawaited(_lan?.close());
    _lan = null;
    _alerts.clear();
    state = AppState(
      saveDir: state.saveDir,
      transferMode: state.transferMode,
      autoAccept: state.autoAccept,
      section: state.section, // stay on the current page after sign-out
      notifyEnabled: state.notifyEnabled,
      notifyPreview: state.notifyPreview,
    );
    unawaited(_syncUnread());
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
    final list = (j['transfers'] as List).map((e) => Transfer.fromJson(e)).where((t) => !_hiddenTasks.contains(t.id)).toList();
    for (final t in list) {
      t.savedPath = _savedPaths[t.id];
    }
    state = state.copyWith(transfers: list);
  }

  void goHome() {
    state = state.copyWith(section: Section.chats, selectedPeer: null, search: '', showingHome: true);
  }

  void setSection(Section s) {
    state = state.copyWith(section: s, showingHome: false);
    _readVisible();
  }
  void setSearch(String s) => state = state.copyWith(search: s);
  void clearError() => state = state.copyWith(error: null);

  Future<void> selectPeer(String id) async {
    state = state.copyWith(selectedPeer: id, section: Section.chats, showingHome: false);
    _readVisible();
    await loadHistory(id);
  }

  Future<void> loadHistory(String peer) async {
    try {
      final j = await _api.request('GET', '/messages', query: {'peer_device_id': peer, 'limit': '100'});
      final server = (j['messages'] as List).map((e) => ChatMessage.fromServer(e, _self)).toList().reversed.toList();
      server.removeWhere((m) => _hiddenMsgs.contains(m.clientId));
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

  @visibleForTesting
  void debugEvent(String type, Map<String, dynamic> data) => _onEvent(WsEvent(type, data));
  @visibleForTesting
  void debugSet(AppState s) => state = s;

  // ---- new-message alerts -------------------------------------------------------------------
  //
  // The model is iMessage / WeChat's:
  //  * the conversation on screen in a focused window never alerts (it is simply read);
  //  * anything else counts as unread: list badge, Dock / launcher / tray count, window title;
  //  * focused window, other conversation  -> a small in-app banner (no system notification);
  //  * window in the background / minimised / hidden to the tray -> a system notification, one per
  //    conversation (a newer one replaces the older), several messages in a burst become one.

  final _alerts = <String, ({int n, String title, String body, Timer timer})>{};

  bool get _viewing => ref.read(appActiveProvider) && state.section == Section.chats && state.selectedPeer != null;

  void _readVisible() {
    if (_viewing) markRead(state.selectedPeer!);
  }

  void markRead(String peerId) {
    _alerts.remove(peerId)?.timer.cancel();
    final t = ref.read(toastProvider);
    if (t != null && t.peerId == peerId) ref.read(toastProvider.notifier).dismiss();
    unawaited(ref.read(systemNotifierProvider).clear(peerId));
    if (!state.unread.containsKey(peerId)) return;
    state = state.copyWith(unread: {...state.unread}..remove(peerId));
    unawaited(_syncUnread());
  }

  Future<void> _syncUnread() async {
    await ref.read(prefsProvider).setString('unread_counts', jsonEncode(state.unread));
    await ref.read(systemNotifierProvider).setUnread(state.totalUnread);
  }

  /// Open a conversation from a notification or banner.
  Future<void> openConversation(String peerId) async {
    ref.read(toastProvider.notifier).dismiss();
    if (state.device(peerId) == null) await loadDevices();
    await selectPeer(peerId);
  }

  String _alertBody(String text) {
    if (!state.notifyPreview) return '发来一条新消息';
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 100 ? '${one.substring(0, 100)}…' : one;
  }

  void _incoming(String peerId, String text, {bool file = false}) {
    final active = ref.read(appActiveProvider);
    if (active && state.section == Section.chats && state.selectedPeer == peerId) return; // already looking at it
    state = state.copyWith(unread: {...state.unread, peerId: (state.unread[peerId] ?? 0) + 1});
    unawaited(_syncUnread());
    if (!state.notifyEnabled) return;
    final title = state.device(peerId)?.name ?? '新消息';
    final body = file && !state.notifyPreview ? '发来一个文件' : _alertBody(text);
    final prev = _alerts[peerId];
    prev?.timer.cancel();
    final n = (prev?.n ?? 0) + 1;
    _alerts[peerId] = (n: n, title: title, body: body, timer: Timer(const Duration(milliseconds: 600), () => _flushAlert(peerId)));
  }

  void _flushAlert(String peerId) {
    final a = _alerts.remove(peerId);
    if (a == null) return;
    final unread = state.unread[peerId] ?? a.n;
    if (ref.read(appActiveProvider)) {
      ref.read(toastProvider.notifier).show(peerId, a.title, a.body, unread);
    } else {
      unawaited(ref.read(systemNotifierProvider).show(peerId: peerId, title: a.title, body: a.body, count: unread));
    }
  }

  Future<void> setNotifyEnabled(bool on) async {
    await ref.read(prefsProvider).setBool('notify_enabled', on);
    state = state.copyWith(notifyEnabled: on);
  }

  Future<void> setNotifyPreview(bool on) async {
    await ref.read(prefsProvider).setBool('notify_preview', on);
    state = state.copyWith(notifyPreview: on);
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
        if (_hiddenMsgs.contains(m.clientId)) return;
        final isNew = _find(m.clientId) == null;
        _upsert(m);
        _rt.send('message.delivered', {'message_id': m.id}); // stored locally → confirm delivery
        if (isNew && !m.mine) _incoming(m.peerId, m.type == 'clipboard' ? '[剪贴板] ${m.content}' : m.content);
      case 'error':
        Log.warn('ws', 'server error ${d['code']}');
        state = state.copyWith(error: d['message']?.toString());
      default:
        if (e.type.startsWith('transfer.')) _onTransferEvent(e);
    }
  }

  Future<void> deleteMessage(ChatMessage m) async {
    _hiddenMsgs.add(m.clientId);
    _setMsgs(m.peerId, [...?state.messages[m.peerId]]..removeWhere((x) => x.clientId == m.clientId));
    await _persist();
  }

  Future<void> clearConversation(String peer) async {
    for (final m in state.messages[peer] ?? const <ChatMessage>[]) {
      _hiddenMsgs.add(m.clientId);
    }
    _setMsgs(peer, []);
    await _persist();
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
  final Map<String, (DateTime, int)> _sample = {}; // speed sampling per task

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
      unawaited(_persist());
    } on ApiException catch (e) {
      Log.warn('transfer', 'create failed ${e.code}');
      state = state.copyWith(error: e.code == 'receiver_offline' ? '目标设备不在线，暂不支持离线文件' : e.message);
    }
  }

  /// PRD FILE-002: several files become several independent tasks.
  Future<void> sendFiles(String peer, Iterable<String> paths) async {
    for (final p in paths) {
      if (await FileSystemEntity.type(p) == FileSystemEntityType.file) await sendFile(peer, p);
    }
  }

  /// PRD FILE-006: retry creates a new task from the original source file.
  Future<void> retryTransfer(Transfer t) async {
    final path = _localPaths[t.id];
    if (path == null || !File(path).existsSync()) {
      state = state.copyWith(error: '源文件已不存在，无法重试');
      return;
    }
    await sendFile(t.receiver, path);
  }

  bool canRetry(Transfer t) =>
      t.sender == _self && !t.active && t.status != 'COMPLETED' && _localPaths[t.id] != null;

  /// PRD 4.9: clearing records never deletes saved files.
  Future<void> clearFinishedTransfers() async {
    final done = state.transfers.where((t) => !t.active).toList();
    _hiddenTasks.addAll(done.map((t) => t.id));
    state = state.copyWith(transfers: state.transfers.where((t) => t.active).toList());
    await _persist();
  }

  Future<void> removeTransferRecord(Transfer t) async {
    if (t.active) return;
    _hiddenTasks.add(t.id);
    state = state.copyWith(transfers: state.transfers.where((x) => x.id != t.id).toList());
    await _persist();
  }

  /// The local file behind a task: the source for files I sent, the saved copy for files I received.
  String? fileOf(Transfer t) => t.sender == _self ? _localPaths[t.id] : t.savedPath;

  bool get canOpenFiles => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<String?> _existing(Transfer t) async {
    final path = fileOf(t);
    if (path == null || !File(path).existsSync()) {
      state = state.copyWith(error: '文件已被移动或删除');
      return null;
    }
    return path;
  }

  /// Open with the default application. PRD 4.6: only ever on an explicit user action.
  Future<void> openFile(Transfer t) async {
    final path = await _existing(t);
    if (path == null) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      state = state.copyWith(error: '无法打开文件');
    }
  }

  /// Show the file in the system file manager.
  Future<void> revealFile(Transfer t) async {
    final path = await _existing(t);
    if (path != null) await _reveal(path);
  }

  Future<void> revealPath(String path) => _reveal(path);

  Future<void> _reveal(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (_) {}
  }

  void _addTransfer(Transfer t) => state = state.copyWith(transfers: [t, ...state.transfers.where((x) => x.id != t.id)]);

  Transfer? _transfer(String id) => state.transfers.where((t) => t.id == id).firstOrNull;

  /// Shared by relay progress events and direct-session progress.
  void _applyProgress(String id, int b) {
    final t = _transfer(id);
    if (t == null) return;
    final now = DateTime.now();
    final last = _sample[id];
    t.startedAt ??= now;
    if (t.status == 'ACCEPTED') t.status = 'TRANSFERRING';
    if (last != null) {
      final dt = now.difference(last.$1).inMilliseconds / 1000;
      if (dt > 0.2) {
        final inst = (b - last.$2) / dt;
        t.speed = t.speed == 0 ? inst : t.speed * 0.6 + inst * 0.4;
        _sample[id] = (now, b);
      }
    } else {
      _sample[id] = (now, b);
    }
    t.bytes = b;
    state = state.copyWith(transfers: [...state.transfers]);
  }

  void _onTransferEvent(WsEvent e) {
    final d = e.data;
    if (e.type == 'transfer.progress') {
      _applyProgress(d['id'], (d['bytes'] as num).toInt());
      return;
    }
    if (d['id'] == null) return;
    final t = Transfer.fromJson(d);
    final prev = _transfer(t.id);
    t.bytes = prev?.bytes ?? 0;
    t.savedPath = prev?.savedPath ?? _savedPaths[t.id];
    t.startedAt = prev?.startedAt;
    t.speed = prev?.speed ?? 0;
    if (!t.active) {
      t.finishedAt = prev?.finishedAt ?? DateTime.now();
      _sample.remove(t.id);
      t.speed = 0;
      if (t.status == 'COMPLETED') t.bytes = t.size;
    }
    _addTransfer(t);
    if (e.type == 'transfer.offer' && t.receiver == _self && !_hiddenTasks.contains(t.id)) {
      if (!canTransferFiles) {
        // The sender must not be left waiting for an answer this device can never give.
        unawaited(reject(t).catchError((Object _) {}));
        _incoming(t.sender, '想发送文件：${t.fileName}（网页版暂不支持接收文件，已自动拒绝）', file: true);
      } else if (state.autoAccept) {
        // Received on its own; the conversation is told when the file has arrived.
        unawaited(accept(t).catchError((Object err) {
          Log.warn('transfer', 'auto-accept failed: ${err.runtimeType}');
        }));
      } else {
        _incoming(t.sender, '想发送文件：${t.fileName}（${fmtBytes(t.size)}）', file: true);
      }
    }
    if (e.type == 'transfer.complete' && t.receiver == _self && prev?.status != 'COMPLETED' && !_hiddenTasks.contains(t.id) && state.autoAccept) {
      _incoming(t.sender, '[文件] ${t.fileName}', file: true);
    }
    if (e.type == 'transfer.accept' && t.sender == _self) unawaited(_startSend(t));
    if (!t.active) _active.remove(t.id)?.close();
  }

  final Set<String> _accepting = {};

  Future<void> accept(Transfer t) async {
    if (!_accepting.add(t.id)) return; // already accepted (e.g. automatically)
    _lanAccepted.add(t.id); // before the request: the sender may connect the moment it hears of the accept
    try {
      await _api.request('POST', '/transfers/${t.id}/accept');
    } catch (_) {
      _lanAccepted.remove(t.id);
      _accepting.remove(t.id);
      rethrow;
    }
    // Pull through the relay right away; if the sender reaches us directly, that request is dropped.
    if (state.transferMode != 'lan') unawaited(_download(t));
  }

  /// Sender: same-network direct first (with resume), relay as the fallback (PRD 4.7).
  Future<void> _startSend(Transfer t) async {
    final path = _localPaths[t.id];
    if (path == null) return;
    final mode = state.transferMode;
    if (mode != 'relay' && t.lanSecret.isNotEmpty && t.lanAddrs.isNotEmpty && t.lanPort > 0) {
      for (var attempt = 0; attempt < 3; attempt++) {
        final out = await lanSend(
          addrs: t.lanAddrs,
          port: t.lanPort,
          taskId: t.id,
          secret: hexToBytes(t.lanSecret),
          file: File(path),
          onProgress: (b) => _applyProgress(t.id, b),
          cancelled: () => !(_transfer(t.id)?.active ?? false),
        );
        if (out == LanSendOutcome.ok) {
          Log.info('lan', 'sent directly');
          return; // the receiver completes the task with the server
        }
        if (!(_transfer(t.id)?.active ?? false)) return; // cancelled meanwhile
        if (out == LanSendOutcome.rejected || out == LanSendOutcome.unreachable) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (mode == 'lan') {
        state = state.copyWith(error: '局域网直连失败（当前设置为仅局域网）');
        await cancel(t);
        return;
      }
      Log.info('lan', 'direct path unavailable, using relay');
    } else if (mode == 'lan') {
      state = state.copyWith(error: '对方设备不在同一局域网，无法直连（当前设置为仅局域网）');
      await cancel(t);
      return;
    }
    await _upload(t);
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
        Log.warn('transfer', 'checksum mismatch ${t.id}');
        await _fail(t, 'checksum mismatch');
        return;
      }
      final target = await _uniqueTarget(dir, t.fileName);
      await part.rename(target.path);
      _savedPaths[t.id] = target.path;
      _transfer(t.id)?.savedPath = target.path;
      unawaited(_persist());
      await _api.request('POST', '/transfers/${t.id}/complete');
    } on FileSystemException catch (e) {
      await _fail(t, e.message.contains('space') ? 'disk full' : 'write error');
      await _tryDelete(part);
    } catch (e) {
      Log.warn('transfer', 'download aborted: ${e.runtimeType}');
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
