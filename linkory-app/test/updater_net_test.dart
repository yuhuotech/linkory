import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/update_install.dart';
import 'package:linkory_app/core/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stand-in for a GitHub accelerator: `GET /<full github url>`.
class FakeMirror {
  FakeMirror(this.handler);
  final FutureOr<List<int>?> Function(String url) handler; // null → 404
  late HttpServer server;
  final hits = <String>[];
  String get base => 'http://127.0.0.1:${server.port}';

  Future<FakeMirror> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final url = req.uri.toString().substring(1); // strip the leading "/"
      hits.add(url);
      final body = await handler(url);
      req.response.statusCode = body == null ? 404 : 200;
      if (body != null) req.response.add(body);
      await req.response.close();
    });
    return this;
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  const api = 'https://api.github.com/repos/x/y';
  const assetName = 'Linkory-0.2.0-linux-amd64.deb';
  final pkg = List<int>.generate(300000, (i) => (i * 7) & 0xff);
  late SimpleKeyPair key;
  late List<int> publicKey;
  late String sums;
  late List<int> sig;

  String releaseJson({String name = assetName}) => jsonEncode([
        {
          'tag_name': 'v0.2.0',
          'prerelease': false,
          'draft': false,
          'html_url': 'https://github.com/x/y/releases/tag/v0.2.0',
          'body': "## What's Changed\n* new",
          'published_at': '2026-10-09T13:00:00Z',
          'assets': [
            for (final n in [name, 'SHA256SUMS.txt', 'SHA256SUMS.txt.sig'])
              {'name': n, 'browser_download_url': 'https://github.com/x/y/releases/download/v0.2.0/$n', 'size': 1},
          ],
        }
      ]);

  setUpAll(() async {
    key = await Ed25519().newKeyPair();
    publicKey = (await key.extractPublicKey()).bytes;
    sums = '${crypto.sha256.convert(pkg)}  $assetName\n';
    sig = (await Ed25519().sign(utf8.encode(sums), keyPair: key)).bytes;
  });

  /// What a healthy accelerator serves.
  FutureOr<List<int>?> good(String url, {List<int>? file, String? sumsText, List<int>? sigBytes, String? feed}) {
    if (url == '$api/releases?per_page=15') return utf8.encode(feed ?? releaseJson());
    if (url.endsWith('/SHA256SUMS.txt')) return utf8.encode(sumsText ?? sums);
    if (url.endsWith('/SHA256SUMS.txt.sig')) return sigBytes ?? sig;
    if (url.endsWith(assetName)) return file ?? pkg;
    return null;
  }

  Future<(ProviderContainer, List<File>)> container(List<String> mirrors, {String apiBase = api, String? planAsset}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final installed = <File>[];
    final c = ProviderContainer(overrides: [
      prefsProvider.overrideWithValue(prefs),
      updateConfigProvider.overrideWithValue(UpdateConfig(
        api: apiBase,
        mirrors: mirrors,
        publicKeyB64: base64Encode(publicKey),
        planFor: (names) async => InstallPlan.fake(planAsset ?? assetName, onInstall: (f) async => installed.add(f)),
      )),
    ]);
    addTearDown(c.dispose);
    return (c, installed);
  }

  test('mirror mode: first accelerator is down, the second serves; signature + hash pass and the installer gets the file', () async {
    final down = await FakeMirror((_) => null).start();
    final up = await FakeMirror(good).start();
    addTearDown(() async {
      await down.stop();
      await up.stop();
    });
    final (c, installed) = await container([down.base, up.base]);
    final n = c.read(updateProvider.notifier);
    await n.setSource(UpdateSource.mirror, recheck: false);
    await n.check(manual: true);
    expect(c.read(updateProvider).latest?.tag, 'v0.2.0');
    expect(c.read(updateProvider).mirrorUsed, up.base);
    // The release feed went through the mirror as `<mirror>/<github api url>`.
    expect(up.hits.first, '$api/releases?per_page=15');
    expect(down.hits, isNotEmpty); // it was tried first

    await n.install();
    expect(c.read(updateProvider).error, isNull);
    expect(installed, hasLength(1));
    expect(installed.single.readAsBytesSync(), pkg);
    expect(up.hits.any((h) => h == 'https://github.com/x/y/releases/download/v0.2.0/$assetName'), isTrue);
  });

  test('a tampered package is rejected even though the mirror served it', () async {
    final evil = List<int>.of(pkg)..[1000] ^= 0xff;
    final m = await FakeMirror((u) => good(u, file: evil)).start();
    addTearDown(m.stop);
    final (c, installed) = await container([m.base]);
    final n = c.read(updateProvider.notifier);
    await n.setSource(UpdateSource.mirror, recheck: false);
    await n.check(manual: true);
    await n.install();
    expect(installed, isEmpty);
    expect(c.read(updateProvider).error, contains('SHA-256'));
  });

  test('a mirror that rewrites SHA256SUMS.txt cannot pass: the signature no longer matches', () async {
    final forged = '${crypto.sha256.convert(utf8.encode('malware'))}  $assetName\n';
    final m = await FakeMirror((u) => good(u, sumsText: forged, file: utf8.encode('malware'))).start();
    addTearDown(m.stop);
    final (c, installed) = await container([m.base]);
    final n = c.read(updateProvider.notifier);
    await n.setSource(UpdateSource.mirror, recheck: false);
    await n.check(manual: true);
    await n.install();
    expect(installed, isEmpty);
    expect(c.read(updateProvider).error, contains('签名'));
  });

  test('a release without a signature file is not auto-installed', () async {
    final feed = jsonEncode([
      {
        'tag_name': 'v0.2.0',
        'prerelease': false,
        'draft': false,
        'html_url': 'x',
        'body': '',
        'published_at': '2026-10-09T13:00:00Z',
        'assets': [
          {'name': assetName, 'browser_download_url': 'https://github.com/x/y/releases/download/v0.2.0/$assetName', 'size': 1},
          {'name': 'SHA256SUMS.txt', 'browser_download_url': 'https://github.com/x/y/releases/download/v0.2.0/SHA256SUMS.txt', 'size': 1},
        ],
      }
    ]);
    final m = await FakeMirror((u) => good(u, feed: feed)).start();
    addTearDown(m.stop);
    final (c, installed) = await container([m.base]);
    final n = c.read(updateProvider.notifier);
    await n.setSource(UpdateSource.mirror, recheck: false);
    await n.check(manual: true);
    await n.install();
    expect(installed, isEmpty);
    expect(c.read(updateProvider).error, contains('校验文件'));
  });

  test('an asset whose name does not carry the release version is refused (rollback protection)', () async {
    final m = await FakeMirror((u) => good(u, feed: releaseJson(name: 'Linkory-0.1.0-linux-amd64.deb'))).start();
    addTearDown(m.stop);
    final (c, installed) = await container([m.base], planAsset: 'Linkory-0.1.0-linux-amd64.deb');
    final n = c.read(updateProvider.notifier);
    await n.setSource(UpdateSource.mirror, recheck: false);
    await n.check(manual: true);
    await n.install();
    expect(installed, isEmpty);
    expect(c.read(updateProvider).error, contains('文件名'));
  });

  test('official mode never touches the mirrors; when GitHub is unreachable the error says how to switch', () async {
    final m = await FakeMirror(good).start();
    addTearDown(m.stop);
    // Nothing listens on this port: GitHub is "unreachable".
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    final (c, _) = await container([m.base], apiBase: 'http://127.0.0.1:$port/repos/x/y');
    final n = c.read(updateProvider.notifier);
    expect(c.read(updateProvider).source, UpdateSource.github, reason: 'the official address is the default');
    await n.check(manual: true);
    expect(c.read(updateProvider).error, contains('国内加速'));
    expect(m.hits, isEmpty);
  });

  test('mirror mode: all accelerators down → a clear error, nothing installed', () async {
    final a = await FakeMirror((_) => null).start();
    final b = await FakeMirror((_) => null).start();
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    final (c, _) = await container([a.base, b.base]);
    final n = c.read(updateProvider.notifier);
    await n.setSource(UpdateSource.mirror, recheck: false);
    await n.check(manual: true);
    expect(c.read(updateProvider).error, contains('国内加速源'));
    expect(c.read(updateProvider).latest, isNull);
  });

  test('viaMirror joins without doubling slashes; the choice is remembered', () async {
    expect(viaMirror('https://gh-proxy.com/', 'https://github.com/a/b'), 'https://gh-proxy.com/https://github.com/a/b');
    expect(viaMirror('https://ghfast.top', 'https://github.com/a/b'), 'https://ghfast.top/https://github.com/a/b');
    final (c, _) = await container(const []);
    await c.read(updateProvider.notifier).setSource(UpdateSource.mirror, recheck: false);
    final prefs = c.read(prefsProvider);
    expect(prefs.getString('update_source'), 'mirror');
    final c2 = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    addTearDown(c2.dispose);
    expect(c2.read(updateProvider).source, UpdateSource.mirror);
  });

  test('random signature bytes do not verify (sanity)', () async {
    final ok = await Ed25519().verify(utf8.encode(sums), signature: Signature(List.generate(64, (_) => Random().nextInt(256)), publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
    expect(ok, isFalse);
  });
}
