import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'log.dart';
import 'session.dart';
import 'update_install.dart';
import 'version.dart';

/// Where releases are published. Tests and local drills point this at a fake feed.
const updateApi = String.fromEnvironment(
  'LINKORY_UPDATE_API',
  defaultValue: 'https://api.github.com/repos/yuhuotech/linkory',
);
const releasesPage = String.fromEnvironment(
  'LINKORY_RELEASES_PAGE',
  defaultValue: 'https://github.com/yuhuotech/linkory/releases',
);

/// Dev/test switch: install the update as soon as one is found, without UI (used by update drills).
const updateAutoInstall = bool.fromEnvironment('LINKORY_UPDATE_AUTOINSTALL');

/// Public half of the release signing key. CI signs SHA256SUMS.txt with the private half
/// (secret UPDATE_SIGNING_KEY); an update is only installed if that signature checks out, so it
/// does not matter which route (GitHub or a third-party mirror) delivered the files.
const updatePublicKeyB64 = String.fromEnvironment(
  'LINKORY_UPDATE_PUBKEY',
  defaultValue: 'TlqsnK0FAtTj6bEdXDLgHg9icGKJXQp4oRJTduGtD3M=',
);

/// Mainland-China GitHub accelerators, tried in this order. Both pass a full GitHub URL through
/// (`<mirror>/https://github.com/...`); gh-proxy.com also relays api.github.com, ghfast.top does not.
const defaultMirrors = String.fromEnvironment(
  'LINKORY_UPDATE_MIRRORS',
  defaultValue: 'https://gh-proxy.com,https://ghfast.top',
);

/// Where updates come from; overridable so tests can point it at local servers.
class UpdateConfig {
  const UpdateConfig({
    this.api = updateApi,
    this.releasesUrl = releasesPage,
    this.mirrors = const ['https://gh-proxy.com', 'https://ghfast.top'],
    this.publicKeyB64 = updatePublicKeyB64,
    this.planFor = InstallPlan.forRelease,
  });
  final String api, releasesUrl, publicKeyB64;
  final List<String> mirrors;
  final Future<InstallPlan> Function(List<String> assetNames) planFor;
}

final updateConfigProvider = Provider<UpdateConfig>(
  (_) => UpdateConfig(
    mirrors: defaultMirrors
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(),
  ),
);

/// `<mirror>/<original url>`
String viaMirror(String mirror, String url) =>
    '${mirror.replaceAll(RegExp(r'/+$'), '')}/$url';

/// Where files are fetched from.
enum UpdateSource { github, mirror }

// ---- versions --------------------------------------------------------------------------------

/// `1.2.3` or `1.2.3-rc4`. A pre-release sorts before its final version; `rc10` after `rc9`.
class SemVer implements Comparable<SemVer> {
  SemVer(this.major, this.minor, this.patch, this.pre);
  final int major, minor, patch;
  final List<String> pre;

  static SemVer? tryParse(String s) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?(?:\+.*)?$')
        .firstMatch(s.trim());
    if (m == null) return null;
    return SemVer(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      m[4] == null ? const [] : m[4]!.split('.'),
    );
  }

  bool get isPrerelease => pre.isNotEmpty;

  @override
  int compareTo(SemVer o) {
    for (final (a, b) in [
      (major, o.major),
      (minor, o.minor),
      (patch, o.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    if (pre.isEmpty || o.pre.isEmpty) {
      return pre.isEmpty == o.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length && i < o.pre.length; i++) {
      final c = _cmpId(pre[i], o.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(o.pre.length);
  }

  // "rc3" vs "rc10": compare the letters, then the trailing number numerically.
  static int _cmpId(String a, String b) {
    final ma = RegExp(r'^(\D*)(\d*)$').firstMatch(a),
        mb = RegExp(r'^(\D*)(\d*)$').firstMatch(b);
    if (ma == null || mb == null) return a.compareTo(b);
    final t = ma[1]!.compareTo(mb[1]!);
    if (t != 0) return t;
    final na = int.tryParse(ma[2]!), nb = int.tryParse(mb[2]!);
    if (na != null && nb != null) return na.compareTo(nb);
    return ma[2]!.compareTo(mb[2]!);
  }

  @override
  String toString() =>
      '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

// ---- feed ------------------------------------------------------------------------------------

class UpdateAsset {
  const UpdateAsset(this.name, this.url, this.size);
  final String name, url;
  final int size;
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.pageUrl,
    required this.prerelease,
    required this.assets,
    this.publishedAt,
  });
  final SemVer version;
  final String tag, notes, pageUrl;
  final bool prerelease;
  final DateTime? publishedAt;
  final List<UpdateAsset> assets;

  UpdateAsset? asset(String name) =>
      assets.where((a) => a.name == name).firstOrNull;
}

/// Newest non-draft release (optionally including pre-releases) from a GitHub "list releases" body.
UpdateInfo? latestRelease(
  List<dynamic> releases, {
  required bool includePrerelease,
}) {
  UpdateInfo? best;
  for (final r in releases.whereType<Map<String, dynamic>>()) {
    if (r['draft'] == true) continue;
    final pre = r['prerelease'] == true;
    if (pre && !includePrerelease) continue;
    final v = SemVer.tryParse('${r['tag_name']}');
    if (v == null) continue;
    if (best != null && v.compareTo(best.version) <= 0) continue;
    best = UpdateInfo(
      version: v,
      tag: '${r['tag_name']}',
      notes: '${r['body'] ?? ''}',
      pageUrl: '${r['html_url'] ?? releasesPage}',
      prerelease: pre,
      publishedAt: DateTime.tryParse('${r['published_at']}'),
      assets: [
        for (final a
            in (r['assets'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          UpdateAsset(
            '${a['name']}',
            '${a['browser_download_url']}',
            (a['size'] as num?)?.toInt() ?? 0,
          ),
      ],
    );
  }
  return best;
}

/// Release notes are the hand-written install table plus GitHub's generated change list; the
/// part users care about in a dialog is the change list.
String shortNotes(String body, {int maxLines = 12}) {
  final i = body.indexOf("## What's Changed");
  var t = (i >= 0 ? body.substring(i + "## What's Changed".length) : body)
      .trim();
  t = t
      .split('\n')
      .where((l) => !l.trim().startsWith('**Full Changelog**'))
      .join('\n')
      .trim();
  final lines = t.split('\n');
  return lines.length <= maxLines ? t : '${lines.take(maxLines).join('\n')}\n…';
}

/// `<hash>  <file>` lines of SHA256SUMS.txt.
String? sha256For(String sums, String file) {
  for (final l in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(l.trim());
    if (m != null && m[2] == file) return m[1]!.toLowerCase();
  }
  return null;
}

// ---- state -----------------------------------------------------------------------------------

enum UpdatePhase { idle, checking, downloading, installing }

class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.latest,
    this.progress = 0,
    this.lastChecked,
    this.error,
    this.autoCheck = true,
    this.includePrerelease = false,
    this.ignored = '',
    this.upToDate = false,
    this.install,
    this.source = UpdateSource.github,
    this.mirrorUsed,
  });
  final UpdatePhase phase;

  /// Where to check and download from. Default: GitHub itself.
  final UpdateSource source;

  /// The accelerator that actually served the last request (for the UI hint).
  final String? mirrorUsed;

  /// A release newer than this build, if one was found.
  final UpdateInfo? latest;
  final double progress;
  final DateTime? lastChecked;
  final String? error;
  final bool autoCheck, includePrerelease;

  /// Version the user chose to ignore (no badge, no dialog on its own).
  final String ignored;

  /// The last check completed and found nothing newer.
  final bool upToDate;

  /// How this build can be updated (null until a release is known).
  final InstallPlan? install;

  bool get available => latest != null;
  bool get badge => latest != null && latest!.tag != ignored;
  bool get busy => phase != UpdatePhase.idle;

  UpdateState copyWith({
    UpdatePhase? phase,
    Object? latest = _keep,
    double? progress,
    Object? lastChecked = _keep,
    Object? error = _keep,
    bool? autoCheck,
    bool? includePrerelease,
    String? ignored,
    bool? upToDate,
    Object? install = _keep,
    UpdateSource? source,
    Object? mirrorUsed = _keep,
  }) => UpdateState(
    phase: phase ?? this.phase,
    latest: identical(latest, _keep) ? this.latest : latest as UpdateInfo?,
    progress: progress ?? this.progress,
    lastChecked: identical(lastChecked, _keep)
        ? this.lastChecked
        : lastChecked as DateTime?,
    error: identical(error, _keep) ? this.error : error as String?,
    autoCheck: autoCheck ?? this.autoCheck,
    includePrerelease: includePrerelease ?? this.includePrerelease,
    ignored: ignored ?? this.ignored,
    upToDate: upToDate ?? this.upToDate,
    install: identical(install, _keep) ? this.install : install as InstallPlan?,
    source: source ?? this.source,
    mirrorUsed: identical(mirrorUsed, _keep)
        ? this.mirrorUsed
        : mirrorUsed as String?,
  );
  static const _keep = Object();
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);

/// Checks GitHub Releases hourly (conditional requests: a 304 costs almost nothing and no battery),
/// and installs the platform's package when the user asks.
class UpdateNotifier extends Notifier<UpdateState> {
  Timer? _timer, _firstCheckTimer, _retryTimer;
  int _retryAttempts = 0;
  http.Client? _dl;
  late final _current =
      SemVer.tryParse(appVersion) ?? SemVer(0, 0, 0, const []);

  static const checkEvery = Duration(hours: 1);
  static const retryDelays = [Duration(minutes: 2), Duration(minutes: 5), Duration(minutes: 15)];

  @override
  UpdateState build() {
    ref.onDispose(() {
      _cancelSchedule();
      _dl?.close();
    });
    final p = ref.read(prefsProvider);
    final last = p.getInt('update_checked_ms');
    return UpdateState(
      autoCheck: p.getBool('update_auto') ?? true,
      // Someone running a release candidate wants to hear about the next one.
      includePrerelease: p.getBool('update_pre') ?? _current.isPrerelease,
      ignored: p.getString('update_ignored') ?? '',
      source: p.getString('update_source') == 'mirror'
          ? UpdateSource.mirror
          : UpdateSource.github,
      lastChecked: last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(last),
    );
  }

  void _cancelSchedule() {
    _timer?.cancel();
    _firstCheckTimer?.cancel();
    _retryTimer?.cancel();
    _timer = _firstCheckTimer = _retryTimer = null;
  }

  /// Always check after launch: a recent persisted check does not restore the
  /// previous in-memory update badge, and a new release may have appeared.
  void start({Duration firstDelay = const Duration(seconds: 20)}) {
    _cancelSchedule();
    _retryAttempts = 0;
    if (!state.autoCheck) return;
    _firstCheckTimer = Timer(firstDelay, () {
      _firstCheckTimer = null;
      if (ref.mounted && state.autoCheck) unawaited(check());
    });
    _timer = Timer.periodic(checkEvery, (_) {
      _retryAttempts = 0;
      if (ref.mounted && state.autoCheck) unawaited(check());
    });
  }

  void _scheduleRetry() {
    if (!state.autoCheck || _timer == null || _retryAttempts >= retryDelays.length) return;
    final delay = retryDelays[_retryAttempts++];
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (ref.mounted && state.autoCheck) unawaited(check());
    });
  }

  Future<void> setAutoCheck(bool on) async {
    await ref.read(prefsProvider).setBool('update_auto', on);
    state = state.copyWith(autoCheck: on);
    if (on) {
      start(firstDelay: const Duration(seconds: 2));
    } else {
      _cancelSchedule();
    }
  }

  Future<void> setIncludePrerelease(bool on) async {
    await ref.read(prefsProvider).setBool('update_pre', on);
    state = state.copyWith(includePrerelease: on);
    await check(manual: true);
  }

  Future<void> ignoreLatest() async {
    final tag = state.latest?.tag;
    if (tag == null) return;
    await ref.read(prefsProvider).setString('update_ignored', tag);
    state = state.copyWith(ignored: tag);
  }

  Future<void> setSource(UpdateSource src, {bool recheck = true}) async {
    await ref.read(prefsProvider).setString('update_source', src.name);
    state = state.copyWith(source: src, mirrorUsed: null, error: null);
    if (recheck) await check(manual: true);
  }

  UpdateConfig get _cfg => ref.read(updateConfigProvider);

  /// GET [url] (a github.com / api.github.com address) from the chosen source. Mirror mode walks the
  /// accelerators until one answers 200; every mirror is a plain pass-through, so content is verified
  /// by signature afterwards, not trusted.
  Future<http.StreamedResponse> _get(
    String url,
    http.Client client, {
    Map<String, String> headers = const {},
    Duration headerTimeout = const Duration(seconds: 20),
  }) async {
    if (state.source == UpdateSource.github) {
      final r = await client
          .send(http.Request('GET', Uri.parse(url))..headers.addAll(headers))
          .timeout(headerTimeout);
      return r;
    }
    Object? last;
    for (final m in _cfg.mirrors) {
      try {
        final r = await client
            .send(
              http.Request('GET', Uri.parse(viaMirror(m, url)))
                ..headers.addAll(headers),
            )
            .timeout(headerTimeout);
        if (r.statusCode == 200) {
          if (state.mirrorUsed != m) state = state.copyWith(mirrorUsed: m);
          return r;
        }
        await r.stream.drain<void>();
        last = 'HTTP ${r.statusCode}';
      } catch (e) {
        last = e;
      }
    }
    throw '国内加速源暂时都不可用（$last），可稍后重试或切换为 GitHub 官方地址';
  }

  Future<List<int>> _getBytes(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final c = http.Client();
    try {
      final r = await _get(url, c, headers: headers);
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      return await r.stream.toBytes().timeout(const Duration(seconds: 60));
    } finally {
      c.close();
    }
  }

  /// [manual]: explicit checks un-ignore the latest version. Errors from all
  /// checks are visible in settings; automatic checks never open an error dialog.
  Future<void> check({bool manual = false}) async {
    if (state.busy) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (manual) _retryAttempts = 0;
    state = state.copyWith(phase: UpdatePhase.checking, error: null);
    try {
      final p = ref.read(prefsProvider);
      final direct = state.source == UpdateSource.github;
      final feedUrl = '${_cfg.api}/releases?per_page=15';
      // Conditional requests only on the direct route (a 304 costs nothing); mirrors may not pass them on.
      final etag = direct && !manual ? p.getString('update_etag') : null;
      final c = http.Client();
      String body;
      try {
        final r = await _get(
          feedUrl,
          c,
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'linkory/$appVersion',
            if (etag != null && p.getString('update_feed') != null)
              'If-None-Match': etag,
          },
        );
        if (r.statusCode == 304) {
          body = p.getString('update_feed') ?? '[]';
          await r.stream.drain<void>();
        } else if (r.statusCode == 200) {
          body = utf8.decode(await r.stream.toBytes());
          final tag = r.headers['etag'];
          if (direct && tag != null) {
            await p.setString('update_etag', tag);
            await p.setString('update_feed', body);
          }
        } else {
          throw 'GitHub 返回 ${r.statusCode}';
        }
      } finally {
        c.close();
      }
      final found = latestRelease(
        jsonDecode(body) as List,
        includePrerelease: state.includePrerelease,
      );
      final newer = found != null && found.version.compareTo(_current) > 0
          ? found
          : null;
      final now = DateTime.now();
      await p.setInt('update_checked_ms', now.millisecondsSinceEpoch);
      if (manual && newer != null && state.ignored == newer.tag) {
        await p.remove('update_ignored');
      }
      if (!ref.mounted) return;
      _retryAttempts = 0;
      state = state.copyWith(
        phase: UpdatePhase.idle,
        latest: newer,
        upToDate: newer == null,
        lastChecked: now,
        ignored: manual && newer != null && state.ignored == newer.tag
            ? ''
            : null,
        install: newer == null
            ? null
            : await _cfg.planFor(newer.assets.map((a) => a.name).toList()),
      );
      Log.info(
        'update',
        newer == null ? 'up to date ($appVersion)' : 'found ${newer.tag}',
      );
      if (newer != null && updateAutoInstall) unawaited(install());
    } catch (e, st) {
      Log.error('update', 'check failed: $e', st);
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: UpdatePhase.idle,
        error: '检查更新失败：${_msg(e)}',
      );
      if (!manual) _scheduleRetry();
    }
  }

  String _msg(Object e) {
    final net =
        e is TimeoutException ||
        e is SocketException ||
        e is http.ClientException;
    if (net && state.source == UpdateSource.github) {
      return '无法连接 GitHub。如果你所在的网络访问不了 GitHub，请把下载源切换为「国内加速」';
    }
    return net ? '网络连接失败' : '$e';
  }

  Future<void> openReleasePage() async {
    final url = state.latest?.pageUrl ?? _cfg.releasesUrl;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Download the package for this platform, verify it (signed SHA256SUMS.txt → file hash), hand over to the installer.
  Future<void> install() async {
    final info = state.latest, plan = state.install;
    if (info == null || plan == null || !plan.canAutoInstall || state.busy) {
      return;
    }
    final asset = info.asset(plan.assetName!);
    if (asset == null) return;
    state = state.copyWith(
      phase: UpdatePhase.downloading,
      progress: 0,
      error: null,
    );
    try {
      // A release's files are named after its own version; this stops a tampered feed from pairing a
      // newer-looking tag with an older (validly signed) package.
      if (!asset.name.startsWith('Linkory-${info.version}-')) {
        throw '安装包文件名与版本不符，已中止';
      }

      final sums = info.asset('SHA256SUMS.txt'),
          sig = info.asset('SHA256SUMS.txt.sig');
      if (sums == null || sig == null) {
        throw '发布缺少校验文件（SHA256SUMS.txt / .sig），无法安全更新，请前往下载页手动下载';
      }
      final sumsBytes = await _getBytes(sums.url);
      final sigBytes = await _getBytes(sig.url);
      final ok = await cg.Ed25519().verify(
        sumsBytes,
        signature: cg.Signature(
          sigBytes,
          publicKey: cg.SimplePublicKey(
            base64Decode(_cfg.publicKeyB64),
            type: cg.KeyPairType.ed25519,
          ),
        ),
      );
      if (!ok) throw '更新校验文件的签名无效（可能被篡改），已中止';
      final want = sha256For(utf8.decode(sumsBytes), asset.name);
      if (want == null) throw 'SHA256SUMS.txt 中没有 ${asset.name}';

      // Android: the app cache dir (what the installer's FileProvider exposes); elsewhere the system temp.
      final base = Platform.isAndroid
          ? await getTemporaryDirectory()
          : Directory.systemTemp;
      final dir = await base.createTemp('linkory-update-');
      final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
      _dl = http.Client();
      final resp = await _get(
        asset.url,
        _dl!,
        headers: {'User-Agent': 'linkory/$appVersion'},
        headerTimeout: const Duration(seconds: 30),
      );
      if (resp.statusCode != 200) throw '下载失败（HTTP ${resp.statusCode}）';
      final total = resp.contentLength ?? asset.size;
      final sink = file.openWrite();
      var got = 0, lastTick = DateTime.now();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 &&
            DateTime.now().difference(lastTick).inMilliseconds > 100) {
          lastTick = DateTime.now();
          state = state.copyWith(progress: (got / total).clamp(0.0, 1.0));
        }
      }
      await sink.close();
      _dl?.close();
      _dl = null;

      final have = (await crypto.sha256.bind(file.openRead()).first).toString();
      if (have != want) {
        await dir.delete(recursive: true);
        throw '安装包校验失败（SHA-256 不一致），已丢弃';
      }
      state = state.copyWith(phase: UpdatePhase.installing, progress: 1);
      await plan.install(file);
      // On success the installer restarts the app; if we are still here, it was handed to the system.
      state = state.copyWith(phase: UpdatePhase.idle);
    } catch (e) {
      Log.warn('update', 'install failed: $e');
      state = state.copyWith(phase: UpdatePhase.idle, error: '$e');
    }
  }

  void cancelDownload() {
    _dl?.close();
    _dl = null;
    state = state.copyWith(phase: UpdatePhase.idle, progress: 0);
  }
}
