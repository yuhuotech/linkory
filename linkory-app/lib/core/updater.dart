import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'log.dart';
import 'session.dart';
import 'update_install.dart';
import 'version.dart';

/// Where releases are published. Tests and local drills point this at a fake feed.
const updateApi = String.fromEnvironment('LINKORY_UPDATE_API', defaultValue: 'https://api.github.com/repos/yuhuotech/linkory');
const releasesPage = String.fromEnvironment('LINKORY_RELEASES_PAGE', defaultValue: 'https://github.com/yuhuotech/linkory/releases');

/// Dev/test switch: install the update as soon as one is found, without UI (used by update drills).
const updateAutoInstall = bool.fromEnvironment('LINKORY_UPDATE_AUTOINSTALL');

// ---- versions --------------------------------------------------------------------------------

/// `1.2.3` or `1.2.3-rc4`. A pre-release sorts before its final version; `rc10` after `rc9`.
class SemVer implements Comparable<SemVer> {
  SemVer(this.major, this.minor, this.patch, this.pre);
  final int major, minor, patch;
  final List<String> pre;

  static SemVer? tryParse(String s) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?(?:\+.*)?$').firstMatch(s.trim());
    if (m == null) return null;
    return SemVer(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m[4] == null ? const [] : m[4]!.split('.'));
  }

  bool get isPrerelease => pre.isNotEmpty;

  @override
  int compareTo(SemVer o) {
    for (final (a, b) in [(major, o.major), (minor, o.minor), (patch, o.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    if (pre.isEmpty || o.pre.isEmpty) return pre.isEmpty == o.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    for (var i = 0; i < pre.length && i < o.pre.length; i++) {
      final c = _cmpId(pre[i], o.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(o.pre.length);
  }

  // "rc3" vs "rc10": compare the letters, then the trailing number numerically.
  static int _cmpId(String a, String b) {
    final ma = RegExp(r'^(\D*)(\d*)$').firstMatch(a), mb = RegExp(r'^(\D*)(\d*)$').firstMatch(b);
    if (ma == null || mb == null) return a.compareTo(b);
    final t = ma[1]!.compareTo(mb[1]!);
    if (t != 0) return t;
    final na = int.tryParse(ma[2]!), nb = int.tryParse(mb[2]!);
    if (na != null && nb != null) return na.compareTo(nb);
    return ma[2]!.compareTo(mb[2]!);
  }

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

// ---- feed ------------------------------------------------------------------------------------

class UpdateAsset {
  const UpdateAsset(this.name, this.url, this.size);
  final String name, url;
  final int size;
}

class UpdateInfo {
  const UpdateInfo({required this.version, required this.tag, required this.notes, required this.pageUrl, required this.prerelease, required this.assets, this.publishedAt});
  final SemVer version;
  final String tag, notes, pageUrl;
  final bool prerelease;
  final DateTime? publishedAt;
  final List<UpdateAsset> assets;

  UpdateAsset? asset(String name) => assets.where((a) => a.name == name).firstOrNull;
}

/// Newest non-draft release (optionally including pre-releases) from a GitHub "list releases" body.
UpdateInfo? latestRelease(List<dynamic> releases, {required bool includePrerelease}) {
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
        for (final a in (r['assets'] as List? ?? const []).whereType<Map<String, dynamic>>())
          UpdateAsset('${a['name']}', '${a['browser_download_url']}', (a['size'] as num?)?.toInt() ?? 0),
      ],
    );
  }
  return best;
}

/// Release notes are the hand-written install table plus GitHub's generated change list; the
/// part users care about in a dialog is the change list.
String shortNotes(String body, {int maxLines = 12}) {
  final i = body.indexOf("## What's Changed");
  var t = (i >= 0 ? body.substring(i + "## What's Changed".length) : body).trim();
  t = t.split('\n').where((l) => !l.trim().startsWith('**Full Changelog**')).join('\n').trim();
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
  });
  final UpdatePhase phase;

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
  }) =>
      UpdateState(
        phase: phase ?? this.phase,
        latest: identical(latest, _keep) ? this.latest : latest as UpdateInfo?,
        progress: progress ?? this.progress,
        lastChecked: identical(lastChecked, _keep) ? this.lastChecked : lastChecked as DateTime?,
        error: identical(error, _keep) ? this.error : error as String?,
        autoCheck: autoCheck ?? this.autoCheck,
        includePrerelease: includePrerelease ?? this.includePrerelease,
        ignored: ignored ?? this.ignored,
        upToDate: upToDate ?? this.upToDate,
        install: identical(install, _keep) ? this.install : install as InstallPlan?,
      );
  static const _keep = Object();
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(UpdateNotifier.new);

/// Checks GitHub Releases hourly (conditional requests: a 304 costs almost nothing and no battery),
/// and installs the platform's package when the user asks.
class UpdateNotifier extends Notifier<UpdateState> {
  Timer? _timer;
  http.Client? _dl;
  late final _current = SemVer.tryParse(appVersion) ?? SemVer(0, 0, 0, const []);

  static const checkEvery = Duration(hours: 1);

  @override
  UpdateState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _dl?.close();
    });
    final p = ref.read(prefsProvider);
    final last = p.getInt('update_checked_ms');
    return UpdateState(
      autoCheck: p.getBool('update_auto') ?? true,
      // Someone running a release candidate wants to hear about the next one.
      includePrerelease: p.getBool('update_pre') ?? _current.isPrerelease,
      ignored: p.getString('update_ignored') ?? '',
      lastChecked: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
    );
  }

  /// Start the hourly schedule. The first check waits a little so it never competes with start-up.
  void start({Duration firstDelay = const Duration(seconds: 20)}) {
    _timer?.cancel();
    if (!state.autoCheck) return;
    final last = state.lastChecked;
    final stale = last == null || DateTime.now().difference(last) > const Duration(minutes: 30);
    if (stale) Timer(firstDelay, () => check());
    _timer = Timer.periodic(checkEvery, (_) => check());
  }

  Future<void> setAutoCheck(bool on) async {
    await ref.read(prefsProvider).setBool('update_auto', on);
    state = state.copyWith(autoCheck: on);
    if (on) {
      start(firstDelay: const Duration(seconds: 2));
    } else {
      _timer?.cancel();
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

  /// [manual]: the user asked, so errors are shown and the ignored version is un-ignored.
  Future<void> check({bool manual = false}) async {
    if (state.busy) return;
    state = state.copyWith(phase: UpdatePhase.checking, error: null);
    try {
      final p = ref.read(prefsProvider);
      final res = await http.get(Uri.parse('$updateApi/releases?per_page=15'), headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'linkory/$appVersion',
        if (!manual && p.getString('update_etag') != null && p.getString('update_feed') != null) 'If-None-Match': p.getString('update_etag')!,
      }).timeout(const Duration(seconds: 20));
      String body;
      if (res.statusCode == 304) {
        body = p.getString('update_feed') ?? '[]';
      } else if (res.statusCode == 200) {
        body = utf8.decode(res.bodyBytes);
        final etag = res.headers['etag'];
        if (etag != null) {
          await p.setString('update_etag', etag);
          await p.setString('update_feed', body);
        }
      } else {
        throw 'GitHub 返回 ${res.statusCode}';
      }
      final found = latestRelease(jsonDecode(body) as List, includePrerelease: state.includePrerelease);
      final newer = found != null && found.version.compareTo(_current) > 0 ? found : null;
      final now = DateTime.now();
      await p.setInt('update_checked_ms', now.millisecondsSinceEpoch);
      if (manual && newer != null && state.ignored == newer.tag) {
        await p.remove('update_ignored');
      }
      state = state.copyWith(
        phase: UpdatePhase.idle,
        latest: newer,
        upToDate: newer == null,
        lastChecked: now,
        ignored: manual && newer != null && state.ignored == newer.tag ? '' : null,
        install: newer == null ? null : await InstallPlan.forRelease(newer.assets.map((a) => a.name).toList()),
      );
      Log.info('update', newer == null ? 'up to date ($appVersion)' : 'found ${newer.tag}');
      if (newer != null && updateAutoInstall) unawaited(install());
    } catch (e, st) {
      Log.error('update', 'check failed: $e', st);
      state = state.copyWith(phase: UpdatePhase.idle, error: manual ? '检查更新失败：${_msg(e)}' : null);
    }
  }

  String _msg(Object e) => e is TimeoutException ? '连接超时' : (e is SocketException ? '无法连接 GitHub' : '$e');

  Future<void> openReleasePage() async {
    final url = state.latest?.pageUrl ?? releasesPage;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Download the package for this platform, verify it against SHA256SUMS.txt, hand over to the installer.
  Future<void> install() async {
    final info = state.latest, plan = state.install;
    if (info == null || plan == null || !plan.canAutoInstall || state.busy) return;
    final asset = info.asset(plan.assetName!);
    if (asset == null) return;
    state = state.copyWith(phase: UpdatePhase.downloading, progress: 0, error: null);
    try {
      final sums = info.asset('SHA256SUMS.txt');
      if (sums == null) throw '发布缺少 SHA256SUMS.txt，无法校验完整性';
      final want = sha256For((await http.get(Uri.parse(sums.url)).timeout(const Duration(seconds: 30))).body, asset.name);
      if (want == null) throw 'SHA256SUMS.txt 中没有 ${asset.name}';

      // Android: the app cache dir (what the installer's FileProvider exposes); elsewhere the system temp.
      final base = Platform.isAndroid ? await getTemporaryDirectory() : Directory.systemTemp;
      final dir = await base.createTemp('linkory-update-');
      final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
      _dl = http.Client();
      final req = http.Request('GET', Uri.parse(asset.url))..headers['User-Agent'] = 'linkory/$appVersion';
      final resp = await _dl!.send(req);
      if (resp.statusCode != 200) throw '下载失败（HTTP ${resp.statusCode}）';
      final total = resp.contentLength ?? asset.size;
      final sink = file.openWrite();
      var got = 0, lastTick = DateTime.now();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && DateTime.now().difference(lastTick).inMilliseconds > 100) {
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
