import 'dart:convert' show ByteConversionSink;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import 'api.dart';
import 'log.dart';
import 'models.dart';
import 'web/browser.dart';

/// Byte-moving half of a relay file transfer (`PUT/GET /transfers/{id}/data`), kept free of app state.
/// `AppStore` decides what to do with the outcome (report failure, record the saved path, ...).

/// Registers how to abort the transfer that is now running.
typedef OnCancel = void Function(void Function() cancel);

enum DownloadStatus { saved, checksumMismatch, diskFull, writeError, aborted }

class DownloadOutcome {
  const DownloadOutcome(this.status, [this.path]);
  final DownloadStatus status;
  final String? path; // set when saved to disk (not for the browser edition)
}

/// SHA-256 of a byte stream, streamed so large files are never held in memory.
Future<String> sha256Hex(Stream<List<int>> bytes) async => (await crypto.sha256.bind(bytes).first).toString();

/// Sender: stream [path] to the relay. Failures are not reported here: the server marks the task FAILED
/// and notifies both ends, and that event updates the UI.
Future<void> relayUpload(ApiClient api, Transfer t, String path, OnCancel onCancel) async {
  final client = http.Client();
  onCancel(client.close);
  try {
    final req = http.StreamedRequest('PUT', api.uri('/transfers/${t.id}/data'))
      ..headers.addAll(api.authHeaders())
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = t.size;
    File(path).openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError, cancelOnError: true);
    final res = await client.send(req);
    await res.stream.drain<void>();
  } catch (_) {
    // see above
  } finally {
    client.close();
  }
}

/// Receiver: write a .part temp file, verify SHA-256, then rename (PRD 4.6 rules).
Future<DownloadOutcome> relayDownload(ApiClient api, Transfer t, Directory dir, OnCancel onCancel) async {
  final client = http.Client();
  onCancel(client.close);
  File? part;
  try {
    await dir.create(recursive: true);
    part = File('${dir.path}${Platform.pathSeparator}.${t.id}.part');
    final res = await client.send(http.Request('GET', api.uri('/transfers/${t.id}/data'))..headers.addAll(api.authHeaders()));
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'download', 'download failed');
    final sink = part.openWrite();
    final hash = _Hasher();
    await for (final chunk in res.stream) {
      sink.add(chunk);
      hash.add(chunk);
    }
    await sink.close();
    if (!hash.matches(t)) {
      await part.delete();
      return const DownloadOutcome(DownloadStatus.checksumMismatch);
    }
    final target = await uniqueTarget(dir, t.fileName);
    await part.rename(target.path);
    return DownloadOutcome(DownloadStatus.saved, target.path);
  } on FileSystemException catch (e) {
    await _tryDelete(part);
    return DownloadOutcome(e.message.contains('space') ? DownloadStatus.diskFull : DownloadStatus.writeError);
  } catch (e) {
    Log.warn('transfer', 'download aborted: ${e.runtimeType}');
    await _tryDelete(part);
    return const DownloadOutcome(DownloadStatus.aborted);
  } finally {
    client.close();
  }
}

/// Browser edition upload.
Future<void> webUpload(ApiClient api, Transfer t, BrowserFile f, OnCancel onCancel) async {
  try {
    await api.request('GET', '/devices'); // the access token may have expired while the offer was waiting
    final up = browserUpload(api.uri('/transfers/${t.id}/data').toString(), {...api.authHeaders(), 'Content-Type': 'application/octet-stream'}, f);
    onCancel(up.abort);
    await up.status;
  } catch (_) {
    // the server reports the failure, as for relayUpload
  }
}

/// Browser edition download: streams into [target], which is finished only when the checksum matches.
Future<DownloadOutcome> webDownload(ApiClient api, Transfer t, BrowserSaveTarget target, OnCancel onCancel) async {
  try {
    final res = await browserFetch(api.uri('/transfers/${t.id}/data').toString(), api.authHeaders());
    onCancel(res.abort);
    if (res.status != 200) throw ApiException(res.status, 'download', 'download failed');
    final hash = _Hasher();
    await for (final chunk in res.body) {
      await target.write(chunk);
      hash.add(chunk);
    }
    if (!hash.matches(t)) {
      await target.abort();
      return const DownloadOutcome(DownloadStatus.checksumMismatch);
    }
    await target.finish();
    return const DownloadOutcome(DownloadStatus.saved);
  } catch (e) {
    Log.warn('transfer', 'download aborted: ${e.runtimeType}');
    await target.abort();
    return const DownloadOutcome(DownloadStatus.aborted);
  }
}

/// Name conflicts never overwrite: "a.txt" -> "a (1).txt".
Future<File> uniqueTarget(Directory dir, String name) async {
  final sep = Platform.pathSeparator;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
  var f = File('${dir.path}$sep$name');
  for (var i = 1; await f.exists(); i++) {
    f = File('${dir.path}$sep$stem ($i)$ext');
  }
  return f;
}

Future<void> _tryDelete(File? f) async {
  try {
    await f?.delete();
  } catch (_) {}
}

/// Incremental SHA-256 plus byte count, compared against what the sender announced.
class _Hasher {
  _Hasher() {
    _acc = crypto.sha256.startChunkedConversion(_Sink((d) => _digest = d));
  }
  late final ByteConversionSink _acc;
  crypto.Digest? _digest;
  int _n = 0;

  void add(List<int> chunk) {
    _acc.add(chunk);
    _n += chunk.length;
  }

  bool matches(Transfer t) {
    _acc.close();
    return _n == t.size && _digest.toString() == t.sha256;
  }
}

class _Sink implements Sink<crypto.Digest> {
  _Sink(this.f);
  final void Function(crypto.Digest) f;
  @override
  void add(crypto.Digest d) => f(d);
  @override
  void close() {}
}
