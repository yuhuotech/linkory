// Same-network direct transfer (PRD 4.7, V1.1).
//
// Wire protocol "LNK1" (see linkory-protocol/PROTOCOL.md §6). Both ends already share a per-task
// 32-byte secret delivered by the server over their authenticated sessions, so:
//   sender → receiver : "LNK1" | task_id(16) | nonceS(16)
//   receiver → sender : nonceR(16) | offset(u64) | HMAC(secret, "R"|id|nonceS|nonceR|offset)
//   sender → receiver : HMAC(secret, "S"|id|nonceS|nonceR|offset)
//   then frames [u32 len][ChaCha20-Poly1305(type|payload)], key = HKDF(secret, nonceS|nonceR),
//   nonce = counter. type 0 = data, 1 = end. Finally receiver → sender: 1 byte (1 = verified OK).
// `offset` is how many bytes the receiver already holds (resume).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

const _magic = [0x4c, 0x4e, 0x4b, 0x31]; // "LNK1"
const lanChunk = 256 * 1024;
const _maxFrame = lanChunk + 64;
final _rnd = Random.secure();

Uint8List _rand(int n) => Uint8List.fromList(List.generate(n, (_) => _rnd.nextInt(256)));

Uint8List uuidBytes(String uuid) {
  final h = uuid.replaceAll('-', '');
  return Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
}

Uint8List hexToBytes(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

Uint8List _u64(int v) => (ByteData(8)..setUint64(0, v)).buffer.asUint8List();

Uint8List _proof(Uint8List secret, String role, Uint8List id, Uint8List ns, Uint8List nr, int offset) {
  final h = c.Hmac(c.sha256, secret);
  return Uint8List.fromList(h.convert([...utf8.encode(role), ...id, ...ns, ...nr, ..._u64(offset)]).bytes);
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// Buffered exact-length reads over a socket stream.
class _Reader {
  _Reader(Stream<Uint8List> s) {
    _sub = s.listen((d) {
      _q.add(d);
      _have += d.length;
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    }, onError: (Object e) {
      _closed = true;
      _wake();
    });
  }
  late final StreamSubscription<Uint8List> _sub;
  final _q = <Uint8List>[];
  int _have = 0;
  bool _closed = false;
  Completer<void>? _w;

  void _wake() {
    final w = _w;
    _w = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List> read(int n, {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_have < n) {
      if (_closed) throw const SocketException('connection closed');
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('read timeout');
      _w = Completer<void>();
      await _w!.future.timeout(left);
    }
    final out = Uint8List(n);
    var o = 0;
    while (o < n) {
      final h = _q.first;
      final take = min(h.length, n - o);
      out.setRange(o, o + take, h);
      o += take;
      if (take == h.length) {
        _q.removeAt(0);
      } else {
        _q[0] = Uint8List.sublistView(h, take);
      }
    }
    _have -= n;
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}

class _Aead {
  _Aead(this._key);
  final SecretKey _key;
  final _alg = Chacha20.poly1305Aead();
  int _n = 0;

  static Future<_Aead> derive(Uint8List secret, Uint8List ns, Uint8List nr) async {
    final k = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: SecretKey(secret), nonce: [...ns, ...nr], info: utf8.encode('linkory-lan-v1'));
    return _Aead(k);
  }

  List<int> _nonce() => [0, 0, 0, 0, ..._u64(_n++)];

  Future<Uint8List> seal(int type, List<int> payload) async {
    final box = await _alg.encrypt([type, ...payload], secretKey: _key, nonce: _nonce());
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<(int, Uint8List)> open(Uint8List frame) async {
    if (frame.length < 17) throw const FormatException('short frame');
    final box = SecretBox(frame.sublist(0, frame.length - 16), nonce: _nonce(), mac: Mac(frame.sublist(frame.length - 16)));
    final plain = await _alg.decrypt(box, secretKey: _key);
    return (plain[0], Uint8List.fromList(plain.sublist(1)));
  }
}

// ---- sender ---------------------------------------------------------------------------------

enum LanSendOutcome { ok, rejected, failed }

/// Connects to the receiver's candidate addresses and streams [file] (resuming at the receiver's
/// offset). Returns `ok` only when the receiver confirms size + SHA-256.
Future<LanSendOutcome> lanSend({
  required List<String> addrs,
  required int port,
  required String taskId,
  required Uint8List secret,
  required File file,
  void Function(int bytes)? onProgress,
  Duration connectTimeout = const Duration(seconds: 2),
  bool Function()? cancelled,
}) async {
  final sock = await _connectAny(addrs, port, connectTimeout);
  if (sock == null) return LanSendOutcome.failed;
  sock.setOption(SocketOption.tcpNoDelay, true);
  final r = _Reader(sock);
  try {
    final id = uuidBytes(taskId), ns = _rand(16);
    sock.add([..._magic, ...id, ...ns]);
    final head = await r.read(16 + 8 + 32, timeout: const Duration(seconds: 10));
    final nr = head.sublist(0, 16);
    final offset = ByteData.sublistView(head, 16, 24).getUint64(0);
    if (!_eq(head.sublist(24), _proof(secret, 'R', id, ns, nr, offset))) return LanSendOutcome.rejected; // not our peer
    sock.add(_proof(secret, 'S', id, ns, nr, offset));
    final len = await file.length();
    if (offset > len) return LanSendOutcome.failed;

    final aead = await _Aead.derive(secret, ns, nr);
    var sent = offset;
    onProgress?.call(sent);
    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      while (sent < len) {
        if (cancelled?.call() == true) return LanSendOutcome.failed;
        final buf = await raf.read(min(lanChunk, len - sent));
        if (buf.isEmpty) return LanSendOutcome.failed;
        final f = await aead.seal(0, buf);
        sock.add([...(ByteData(4)..setUint32(0, f.length)).buffer.asUint8List(), ...f]);
        sent += buf.length;
        onProgress?.call(sent);
        await sock.flush(); // back-pressure: keep memory flat
      }
    } finally {
      await raf.close();
    }
    final end = await aead.seal(1, const []);
    sock.add([...(ByteData(4)..setUint32(0, end.length)).buffer.asUint8List(), ...end]);
    await sock.flush();
    final ack = await r.read(1, timeout: const Duration(seconds: 60));
    return ack[0] == 1 ? LanSendOutcome.ok : LanSendOutcome.rejected;
  } catch (_) {
    return LanSendOutcome.failed;
  } finally {
    await r.cancel();
    sock.destroy();
  }
}

Future<Socket?> _connectAny(List<String> addrs, int port, Duration timeout) async {
  if (addrs.isEmpty) return null;
  final done = Completer<Socket?>();
  var pending = addrs.length;
  for (final a in addrs) {
    Socket.connect(a, port, timeout: timeout).then((s) {
      if (done.isCompleted) {
        s.destroy();
      } else {
        done.complete(s);
      }
    }).catchError((Object _) {
      if (--pending == 0 && !done.isCompleted) done.complete(null);
    });
  }
  return done.future;
}

// ---- receiver -------------------------------------------------------------------------------

/// What the listener needs to know about a task the user accepted.
class LanIncoming {
  LanIncoming({required this.taskId, required this.secret, required this.size, required this.sha256, required this.part});
  final String taskId;
  final Uint8List secret;
  final int size;
  final String sha256; // lowercase hex
  final File part; // resumable temp file; kept on interrupted sessions
}

class LanHooks {
  LanHooks({required this.lookup, this.onStart, this.onProgress, required this.onVerified, this.onFailed});

  /// Task by id, or null if not accepted by this device (connection is dropped).
  final LanIncoming? Function(String taskId) lookup;

  /// An authenticated sender connected (before any data).
  final void Function(String taskId)? onStart;
  final void Function(String taskId, int bytes)? onProgress;

  /// All bytes received and SHA-256 matched; the part file is complete. Return false to refuse
  /// (e.g. the rename failed) so the sender does not consider it delivered.
  final Future<bool> Function(String taskId, File part) onVerified;

  /// Session ended without a verified file ([corrupt] = hash/size mismatch, part was removed).
  final void Function(String taskId, {required bool corrupt})? onFailed;
}

class LanListener {
  LanListener._(this._server, this._hooks) {
    _server.listen(_handle);
  }
  final ServerSocket _server;
  final LanHooks _hooks;
  final _active = <String>{};

  int get port => _server.port;

  static Future<LanListener> bind(LanHooks hooks, {int port = 0}) async =>
      LanListener._(await ServerSocket.bind(InternetAddress.anyIPv4, port), hooks);

  Future<void> close() => _server.close();

  Future<void> _handle(Socket sock) async {
    sock.setOption(SocketOption.tcpNoDelay, true);
    final r = _Reader(sock);
    String? tid;
    var authed = false;
    try {
      final hello = await r.read(4 + 16 + 16, timeout: const Duration(seconds: 10));
      if (!_eq(hello.sublist(0, 4), _magic)) return;
      final id = hello.sublist(4, 20), ns = hello.sublist(20);
      final taskId = _fmtUuid(id);
      final task = _hooks.lookup(taskId);
      if (task == null || _active.contains(taskId)) return;
      tid = taskId;
      _active.add(taskId);

      // Resume: hash what we already have so the digest covers the whole file.
      var have = task.part.existsSync() ? task.part.lengthSync() : 0;
      if (have > task.size) {
        await task.part.delete();
        have = 0;
      }
      final acc = _Hash();
      if (have > 0) {
        await for (final ch in task.part.openRead()) {
          acc.add(ch);
        }
      }
      final nr = _rand(16);
      sock.add([...nr, ..._u64(have), ..._proof(task.secret, 'R', id, ns, nr, have)]);
      final sp = await r.read(32, timeout: const Duration(seconds: 10));
      if (!_eq(sp, _proof(task.secret, 'S', id, ns, nr, have))) return;
      authed = true;
      _hooks.onStart?.call(taskId);

      final aead = await _Aead.derive(task.secret, ns, nr);
      final sink = task.part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have;
      var ended = false;
      try {
        while (!ended) {
          final len = ByteData.sublistView(await r.read(4, timeout: const Duration(seconds: 30))).getUint32(0);
          if (len > _maxFrame) throw const FormatException('frame too large');
          final (type, payload) = await aead.open(await r.read(len, timeout: const Duration(seconds: 30)));
          if (type == 1) {
            ended = true;
          } else {
            sink.add(payload);
            acc.add(payload);
            got += payload.length;
            if (got > task.size) throw const FormatException('too many bytes');
            _hooks.onProgress?.call(taskId, got);
          }
        }
      } finally {
        await sink.close();
      }
      final ok = got == task.size && acc.hex() == task.sha256;
      if (!ok) {
        try {
          await task.part.delete();
        } catch (_) {}
        sock.add([0]);
        _hooks.onFailed?.call(taskId, corrupt: true);
        return;
      }
      final saved = await _hooks.onVerified(taskId, task.part);
      sock.add([saved ? 1 : 0]);
      await sock.flush();
      if (!saved) _hooks.onFailed?.call(taskId, corrupt: false);
    } catch (_) {
      if (authed && tid != null) _hooks.onFailed?.call(tid, corrupt: false); // interrupted: part kept for resume
    } finally {
      if (tid != null) _active.remove(tid);
      await r.cancel();
      sock.destroy();
    }
  }
}

String _fmtUuid(List<int> b) {
  String h(int a, int z) => b.sublist(a, z).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
}

class _Hash {
  _Hash() {
    _in = c.sha256.startChunkedConversion(_Sink((d) => _d = d));
  }
  late final Sink<List<int>> _in;
  c.Digest? _d;
  void add(List<int> b) => _in.add(b);
  String hex() {
    _in.close();
    return _d.toString();
  }
}

class _Sink implements Sink<c.Digest> {
  _Sink(this.f);
  final void Function(c.Digest) f;
  @override
  void add(c.Digest d) => f(d);
  @override
  void close() {}
}

/// Private IPv4 addresses of this machine, for the server to hand to the peer.
Future<List<String>> localLanAddresses() async {
  final out = <String>[];
  try {
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (!a.isLoopback && (a.rawAddress[0] == 10 || (a.rawAddress[0] == 172 && (a.rawAddress[1] & 0xf0) == 16) || (a.rawAddress[0] == 192 && a.rawAddress[1] == 168) || (a.rawAddress[0] == 169 && a.rawAddress[1] == 254))) {
          out.add(a.address);
        }
      }
    }
  } catch (_) {}
  return out;
}
