import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/updater.dart';
import '../../core/version.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

String _when(DateTime? t) => t == null ? '尚未检查' : fmtDaySeparator(t);

/// Opens the "new version" dialog (also reachable from the update arrow above the settings button).
Future<void> showUpdateDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _UpdateDialog());

class _UpdateDialog extends ConsumerWidget {
  const _UpdateDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final u = ref.watch(updateProvider);
    final n = ref.read(updateProvider.notifier);
    final info = u.latest;
    if (info == null) {
      // Everything was applied or withdrawn while the dialog was open.
      WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.of(context).maybePop());
      return const SizedBox.shrink();
    }
    final plan = u.install;
    final can = plan?.canAutoInstall ?? false;
    Widget kv(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [SizedBox(width: 72, child: Text(k, style: Type.body.copyWith(color: c.text3))), Expanded(child: v)]),
        );
    final notes = shortNotes(info.notes);
    return Dialog(
      backgroundColor: c.bgCard,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog), side: BorderSide(color: c.border)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.circleArrowUp, size: 20, color: c.action),
              const SizedBox(width: 8),
              Expanded(child: Text('发现新版本', style: Type.title.copyWith(color: c.text1))),
              if (!u.busy) LIconButton(icon: LucideIcons.x, tooltip: '关闭', onPressed: () => Navigator.of(context).maybePop()),
            ]),
            const SizedBox(height: 12),
            kv('当前版本', Text(appVersion, style: Type.body.copyWith(color: c.text1))),
            kv(
                '最新版本',
                Row(children: [
                  Text(info.version.toString(), style: Type.strong.copyWith(color: c.actionText)),
                  if (info.prerelease) ...[const SizedBox(width: 6), const LBadge('预发布')],
                  if (info.publishedAt != null) ...[const SizedBox(width: 8), Text(_when(info.publishedAt!.toLocal()), style: Type.caption.copyWith(color: c.text3))],
                ])),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 160),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: c.bgSubtle, borderRadius: BorderRadius.circular(Radii.control)),
                child: SingleChildScrollView(child: ReleaseNotes(data: notes)),
              ),
            ],
            if (plan?.manualReason != null) ...[
              const SizedBox(height: 10),
              Text(plan!.manualReason!, style: Type.caption.copyWith(color: c.text3)),
            ],
            if (!u.busy) ...[
              const SizedBox(height: 14),
              Text('下载源', style: Type.caption.copyWith(color: c.text3)),
              const SizedBox(height: 6),
              const UpdateSourcePicker(),
            ],
            if (u.phase == UpdatePhase.downloading || u.phase == UpdatePhase.installing) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                    value: u.phase == UpdatePhase.installing ? null : u.progress, minHeight: 4, backgroundColor: c.bgSubtle, color: c.action),
              ),
              const SizedBox(height: 6),
              Text(u.phase == UpdatePhase.installing ? '正在安装，应用即将自动重启…' : '正在下载 ${(u.progress * 100).floor()}%', style: Type.caption.copyWith(color: c.text2)),
            ],
            if (u.error != null) ...[
              const SizedBox(height: 10),
              Text(u.error!, style: Type.caption.copyWith(color: c.dangerText)),
            ],
            const SizedBox(height: 18),
            Row(children: [
              if (!u.busy) LButton(label: '忽略此版本', variant: BtnVariant.ghost, compact: true, onPressed: () async {
                    await n.ignoreLatest();
                    if (context.mounted) Navigator.of(context).maybePop();
                  }),
              const Spacer(),
              if (u.phase == UpdatePhase.downloading)
                LButton(label: '取消', onPressed: n.cancelDownload)
              else ...[
                LButton(label: '前往下载页', icon: LucideIcons.externalLink, onPressed: u.busy ? null : n.openReleasePage),
                if (can) ...[
                  const SizedBox(width: 8),
                  LButton(
                      label: u.phase == UpdatePhase.installing ? '安装中…' : '立即更新',
                      variant: BtnVariant.solid,
                      icon: LucideIcons.download,
                      loading: u.phase == UpdatePhase.installing,
                      onPressed: u.busy ? null : n.install),
                ],
              ],
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Settings → 软件更新.
class UpdatePanel extends ConsumerWidget {
  const UpdatePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final u = ref.watch(updateProvider);
    final n = ref.read(updateProvider.notifier);
    Widget row(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 120, child: Text(k, style: Type.body.copyWith(color: c.text2))),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: v)),
          ]),
        );
    Text t(String s, {Color? color}) => Text(s, style: Type.body.copyWith(color: color ?? c.text1));

    final status = u.phase == UpdatePhase.checking
        ? t('正在检查…', color: c.text2)
        : u.error != null
            ? t(u.error!, color: c.dangerText)
            : u.available
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    LBadge('新版本', bg: c.actionSoft, fg: c.actionText),
                    const SizedBox(width: 8),
                    Text(u.latest!.version.toString(), style: Type.strong.copyWith(color: c.actionText)),
                  ])
                : u.upToDate
                    ? Row(mainAxisSize: MainAxisSize.min, children: [Icon(LucideIcons.circleCheck, size: 14, color: c.successText), const SizedBox(width: 6), t('已是最新版本', color: c.successText)])
                    : t('尚未检查', color: c.text3);

    return Column(children: [
      row(
          '当前版本',
          Row(mainAxisSize: MainAxisSize.min, children: [
            t(appVersion),
            if (appVersion.contains('-')) ...[const SizedBox(width: 6), const LBadge('预发布')],
          ])),
      row('更新状态', status),
      row('上次检查', t(_when(u.lastChecked), color: c.text2)),
      row(
          '',
          Wrap(spacing: 8, runSpacing: 8, children: [
            LButton(
                label: u.phase == UpdatePhase.checking ? '检查中…' : '检查更新',
                icon: LucideIcons.refreshCw,
                loading: u.phase == UpdatePhase.checking,
                onPressed: u.busy ? null : () => n.check(manual: true)),
            if (u.available) LButton(label: '查看新版本', variant: BtnVariant.solid, icon: LucideIcons.circleArrowUp, onPressed: () => showUpdateDialog(context)),
            if (u.available) LButton(label: '前往下载页', icon: LucideIcons.externalLink, onPressed: n.openReleasePage),
          ])),
      row(
          '自动检查',
          Row(mainAxisSize: MainAxisSize.min, children: [
            LSwitch(value: u.autoCheck, onChanged: n.setAutoCheck),
            const SizedBox(width: 10),
            Text('每小时检查一次', style: Type.body.copyWith(color: c.text2)),
          ])),
      row(
          '预发布版本',
          Row(mainAxisSize: MainAxisSize.min, children: [
            LSwitch(value: u.includePrerelease, onChanged: n.setIncludePrerelease),
            const SizedBox(width: 10),
            Text('也提示测试版（rc / beta）', style: Type.body.copyWith(color: c.text2)),
          ])),
      row('下载源', const UpdateSourcePicker(recheck: true)),
      if (u.available && u.install?.manualReason != null) row('说明', Text(u.install!.manualReason!, style: Type.caption.copyWith(color: c.text3))),
    ]);
  }
}

/// Where to check and download from: GitHub itself (default) or the mainland-China accelerators.
class UpdateSourcePicker extends ConsumerWidget {
  const UpdateSourcePicker({super.key, this.recheck = false});

  /// Re-run the update check after switching (settings page); the dialog only changes the download route.
  final bool recheck;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final u = ref.watch(updateProvider);
    final n = ref.read(updateProvider.notifier);
    final mirror = u.source == UpdateSource.mirror;
    Widget opt(UpdateSource s, String label) => LButton(
          label: label,
          compact: true,
          variant: u.source == s ? BtnVariant.solid : BtnVariant.neutral,
          onPressed: u.busy ? null : () => n.setSource(s, recheck: recheck),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        opt(UpdateSource.github, 'GitHub 官方'),
        const SizedBox(width: 6),
        opt(UpdateSource.mirror, '国内加速'),
      ]),
      const SizedBox(height: 6),
      Text(
        mirror
            ? '通过加速站 gh-proxy.com、ghfast.top 中转，失败自动换下一个${u.mirrorUsed == null ? '' : '（当前：${Uri.parse(u.mirrorUsed!).host}）'}。安装包仍用官方签名校验，加速站无法篡改。'
            : '从 github.com 官方地址检查与下载（默认）。访问不了 GitHub 时可切换为「国内加速」。',
        style: Type.caption.copyWith(color: c.text3, height: 1.4),
      ),
    ]);
  }
}
