import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop.dart';
import 'log.dart';

/// How *this* installation can be updated: which release asset to download and what installing it means.
/// When it cannot be done unattended, [manualReason] says why and the UI offers the release page only.
class InstallPlan {
  InstallPlan._(this.kind, this.assetName, this.manualReason, this._installer);

  final String kind; // dmg-zip | windows-setup | deb | tar | apk | manual
  final String? assetName, manualReason;
  final Future<void> Function(File pkg)? _installer;

  bool get canAutoInstall => assetName != null && _installer != null;
  Future<void> install(File pkg) async => _installer!(pkg);

  /// Test doubles for widget tests.
  @visibleForTesting
  factory InstallPlan.fake(String asset) => InstallPlan._('fake', asset, null, (_) async {});
  @visibleForTesting
  factory InstallPlan.fakeManual(String why) => _manual(why);

  static InstallPlan _manual(String why) => InstallPlan._('manual', null, why, null);

  /// Chooses the asset and installer for this machine from the names the release offers.
  static Future<InstallPlan> forRelease(List<String> names) async {
    try {
      if (kIsWeb) return _manual('当前平台不支持自动更新');
      if (Platform.isMacOS) return _mac(names);
      if (Platform.isWindows) return _windows(names);
      if (Platform.isLinux) return await _linux(names);
      if (Platform.isAndroid) return _android(names);
    } catch (e) {
      Log.warn('update', 'plan failed: $e');
    }
    return _manual('当前平台暂不支持自动更新，请前往下载页');
  }

  static String? _find(List<String> names, bool Function(String) test) => names.where(test).firstOrNull;

  // ---- macOS: replace the .app bundle from a zip, after we quit ------------------------------
  static InstallPlan _mac(List<String> names) {
    final asset = _find(names, (n) => n.endsWith('-macos.zip'));
    if (asset == null) return _manual('此版本没有 macOS 更新包');
    if (!Platform.version.contains('arm64')) return _manual('自动更新包仅提供 Apple 芯片版本，请前往下载页');
    final exe = Platform.resolvedExecutable; // …/X.app/Contents/MacOS/linkory_app
    final i = exe.indexOf('.app/Contents/MacOS/');
    if (i < 0) return _manual('无法定位应用包');
    final bundle = exe.substring(0, i + 4);
    if (bundle.startsWith('/Volumes/')) return _manual('请先把应用拖到「应用程序」文件夹，再使用自动更新');
    if (bundle.contains('/AppTranslocation/')) return _manual('应用正在被系统隔离运行，请先移到「应用程序」文件夹并重新打开');
    if (!_writable(Directory(File(bundle).parent.path))) return _manual('没有权限替换 $bundle，请手动更新');
    return InstallPlan._('dmg-zip', asset, null, (pkg) => _installMac(pkg, bundle));
  }

  static Future<void> _installMac(File zip, String bundle) async {
    final stage = await Directory.systemTemp.createTemp('linkory-stage-');
    final r = await Process.run('/usr/bin/ditto', ['-x', '-k', zip.path, stage.path]);
    if (r.exitCode != 0) throw '解压更新包失败';
    final fresh = stage.listSync().whereType<Directory>().where((d) => d.path.endsWith('.app')).firstOrNull;
    if (fresh == null) throw '更新包里没有应用';
    final log = '${stage.path}/update.log';
    await _runAfterExit('''
exec >>${_q(log)} 2>&1
BUNDLE=${_q(bundle)}
NEW=${_q(fresh.path)}
OLD="\$BUNDLE.old.\$\$"
echo "swap \$BUNDLE"
mv "\$BUNDLE" "\$OLD" || exit 1
if /usr/bin/ditto "\$NEW" "\$BUNDLE"; then
  /usr/bin/xattr -cr "\$BUNDLE" 2>/dev/null
  rm -rf "\$OLD"
  echo "updated"
else
  echo "copy failed, restoring"
  rm -rf "\$BUNDLE"; mv "\$OLD" "\$BUNDLE"
fi
/usr/bin/open "\$BUNDLE"
rm -rf ${_q(zip.parent.path)}
''');
  }

  // ---- Windows: run the Inno Setup installer silently over the existing install --------------
  static InstallPlan _windows(List<String> names) {
    final asset = _find(names, (n) => n.endsWith('-windows-x64-setup.exe'));
    if (asset == null) return _manual('此版本没有 Windows 安装程序');
    final dir = File(Platform.resolvedExecutable).parent.path;
    // Inno writes unins000.exe next to the app: its presence means "installed with the installer".
    if (!File('$dir\\unins000.exe').existsSync()) {
      return _manual('当前是免安装版，不能原地更新。请下载安装程序，或解压新版覆盖');
    }
    return InstallPlan._('windows-setup', asset, null, (pkg) async {
      // The installer closes/restarts the app itself (CloseApplications + a silent [Run] entry).
      await Process.start(pkg.path, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/FORCECLOSEAPPLICATIONS'],
          mode: ProcessStartMode.detached);
      await _quit();
    });
  }

  // ---- Linux: .deb through apt when installed from one, else unpack the tar.gz over a writable dir
  static Future<InstallPlan> _linux(List<String> names) async {
    final arch = (await Process.run('uname', ['-m'])).stdout.toString().trim();
    if (arch != 'x86_64') return _manual('自动更新包仅提供 x64 版本，请前往下载页');
    final exe = Platform.resolvedExecutable;
    final appDir = File(exe).parent.path;

    final st = await Process.run('dpkg-query', ['-W', '-f=\${Status}', 'linkory']).catchError((_) => ProcessResult(0, 1, '', ''));
    final viaDeb = st.exitCode == 0 && st.stdout.toString().contains('install ok installed') && exe.startsWith('/opt/linkory-app/');
    if (viaDeb) {
      final asset = _find(names, (n) => n.endsWith('-linux-amd64.deb'));
      if (asset == null) return _manual('此版本没有 .deb 更新包');
      return InstallPlan._('deb', asset, null, (pkg) => _installDeb(pkg, exe));
    }
    final asset = _find(names, (n) => n.endsWith('-linux-x64.tar.gz'));
    if (asset != null && _writable(Directory(appDir))) {
      return InstallPlan._('tar', asset, null, (pkg) => _installTar(pkg, appDir, exe));
    }
    return _manual('当前不是通过 .deb 安装的，且安装目录不可写。请用 .deb 安装包更新（sudo apt install ./Linkory-*.deb）');
  }

  static Future<void> _installDeb(File deb, String exe) async {
    final log = '${deb.parent.path}/update.log';
    await _runAfterExit('''
exec >>${_q(log)} 2>&1
PKG=${_q(deb.path)}
export DEBIAN_FRONTEND=noninteractive
if [ "\$(id -u)" = 0 ]; then apt-get install -y "\$PKG"
elif sudo -n true 2>/dev/null; then sudo -n apt-get install -y "\$PKG"
else pkexec env DEBIAN_FRONTEND=noninteractive apt-get install -y "\$PKG"; fi
echo "apt exit=\$?"
setsid ${_q(exe)} >/dev/null 2>&1 &
''');
  }

  static Future<void> _installTar(File tgz, String appDir, String exe) async {
    final log = '${tgz.parent.path}/update.log';
    await _runAfterExit('''
exec >>${_q(log)} 2>&1
tar -xzf ${_q(tgz.path)} -C ${_q(appDir)} && echo "extracted"
setsid ${_q(exe)} >/dev/null 2>&1 &
''');
  }

  // ---- Android: hand the apk to the system installer -----------------------------------------
  static InstallPlan _android(List<String> names) {
    final asset = _find(names, (n) => n.endsWith('-android.apk'));
    if (asset == null) return _manual('此版本没有 Android 安装包');
    return InstallPlan._('apk', asset, null, (pkg) async {
      const ch = MethodChannel('com.yuhuo.linkory/update');
      final r = await ch.invokeMethod<String>('installApk', pkg.path);
      if (r == 'need_permission') throw '请在系统设置里允许「连信」安装应用，然后再点一次「立即更新」';
    });
  }

  // ---- helpers -------------------------------------------------------------------------------

  static bool _writable(Directory d) {
    try {
      final f = File('${d.path}/.linkory-w-$pid');
      f.writeAsStringSync('x');
      f.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Runs [body] in a detached shell once this process has exited (so files can be replaced), then quits.
  static Future<void> _runAfterExit(String body) async {
    final dir = await Directory.systemTemp.createTemp('linkory-run-');
    final script = File('${dir.path}/update.sh')
      ..writeAsStringSync('''#!/bin/sh
i=0
while kill -0 $pid 2>/dev/null && [ \$i -lt 100 ]; do sleep 0.3; i=\$((i+1)); done
$body
''');
    await Process.start('/bin/sh', [script.path], mode: ProcessStartMode.detached);
    await _quit();
  }

  static Future<void> _quit() async {
    await Future<void>.delayed(const Duration(milliseconds: 400)); // let the UI show "restarting"
    try {
      await DesktopShell.instance?.quit();
    } catch (_) {}
    exit(0);
  }
}
