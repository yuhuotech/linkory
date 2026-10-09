import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/desktop.dart';
import '../../core/log.dart';
import '../../core/session.dart';
import '../../core/store.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';
import '../auth/login_page.dart';

enum SettingsTab { account, general, transfer, about }

class SettingsTabNotifier extends Notifier<SettingsTab> {
  @override
  SettingsTab build() => SettingsTab.account;
  void set(SettingsTab t) => state = t;
}

final settingsTabProvider = NotifierProvider<SettingsTabNotifier, SettingsTab>(SettingsTabNotifier.new);

extension SettingsTabX on SettingsTab {
  String get label => switch (this) { SettingsTab.account => '账号与安全', SettingsTab.general => '通用', SettingsTab.transfer => '传输', SettingsTab.about => '关于' };
  IconData get icon => switch (this) {
        SettingsTab.account => LucideIcons.userRound,
        SettingsTab.general => LucideIcons.settings2,
        SettingsTab.transfer => LucideIcons.arrowLeftRight,
        SettingsTab.about => LucideIcons.info,
      };
}

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => const _PasswordDialog());
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('密码已修改，其他设备已退出登录'), behavior: SnackBarBehavior.floating, width: 360));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final tab = ref.watch(settingsTabProvider);
    final sess = ref.watch(sessionProvider);
    final st = ref.watch(storeProvider);
    final guest = ref.watch(isGuestProvider);

    Widget item(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            SizedBox(width: 120, child: Text(k, style: Type.body.copyWith(color: c.text2))),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: v)),
          ]),
        );
    Text t(String s) => Text(s, style: Type.body.copyWith(color: c.text1));

    final body = switch (tab) {
      SettingsTab.account when guest => [
          item('状态', Row(mainAxisSize: MainAxisSize.min, children: [const LBadge('未登录'), const SizedBox(width: 8), t('登录后才能与其他设备互联')])),
          item('服务器', t(sess.serverUrl)),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              LButton(label: '登录', variant: BtnVariant.solid, icon: LucideIcons.logIn, onPressed: () => showLogin(context)),
              const SizedBox(width: 8),
              LButton(label: '注册账号', onPressed: () => showLogin(context, register: true)),
            ]),
          ),
          const SizedBox(height: 8),
        ],
      SettingsTab.account => [
          item('用户名', t(sess.username)),
          item('服务器', t(sess.serverUrl)),
          item('本机设备 ID', SelectableText(sess.deviceId, style: Type.body.copyWith(color: c.text1))),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              LButton(label: '修改密码', icon: LucideIcons.keyRound, onPressed: () => _changePassword(context, ref)),
              const SizedBox(width: 8),
              LButton(
                label: '退出登录', icon: LucideIcons.logOut, onPressed: () async {
                  ref.read(storeProvider.notifier).stop();
                  await ref.read(sessionProvider.notifier).logout();
                }),
            ]),
          ),
        ],
      SettingsTab.general => [
          item(
            '外观',
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final m in ThemeMode.values) ...[
                LButton(
                  label: switch (m) { ThemeMode.system => '跟随系统', ThemeMode.light => '浅色', ThemeMode.dark => '深色' },
                  compact: true,
                  variant: ref.watch(themeModeProvider) == m ? BtnVariant.solid : BtnVariant.neutral,
                  onPressed: () => ref.read(themeModeProvider.notifier).set(m),
                ),
                const SizedBox(width: 6),
              ],
            ]),
          ),
          if (isDesktop) ...[
            item('关闭窗口时', _Toggle(label: '最小化到托盘，继续接收消息', get: () async => DesktopShell.instance?.closeToTray ?? true, set: (v) async => DesktopShell.instance?.setCloseToTray(v))),
            item('开机启动', _Toggle(label: '登录系统后自动启动', get: DesktopShell.autostartEnabled, set: DesktopShell.setAutostart)),
          ],
          if (Log.dir != null) item('日志目录', Row(children: [
            Flexible(child: t(Log.dir!)),
            const SizedBox(width: 12),
            LButton(label: '打开', compact: true, onPressed: () => ref.read(storeProvider.notifier).revealPath(Log.dir!)),
          ])),
        ],
      SettingsTab.transfer => [
          item(
            '文件保存目录',
            Row(children: [
              Flexible(child: t(st.saveDir)),
              const SizedBox(width: 12),
              LButton(
                  label: '更改',
                  compact: true,
                  onPressed: () async {
                    final dir = await FilePicker.getDirectoryPath();
                    if (dir != null) ref.read(storeProvider.notifier).setSaveDir(dir);
                  }),
            ]),
          ),
          item('同名文件', t('自动重命名，不覆盖已有文件')),
          item(
            '传输方式',
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final m in const [('auto', '自动选择'), ('lan', '仅局域网'), ('relay', '仅公网中转')]) ...[
                LButton(
                  label: m.$2,
                  compact: true,
                  variant: st.transferMode == m.$1 ? BtnVariant.solid : BtnVariant.neutral,
                  onPressed: () => ref.read(storeProvider.notifier).setTransferMode(m.$1),
                ),
                const SizedBox(width: 6),
              ],
            ]),
          ),
          item(
              '说明',
              Text('自动选择：同一局域网内优先直连（端到端加密，速度更快），不可用时自动回退服务端中转。',
                  style: Type.caption.copyWith(color: c.text3))),
        ],
      SettingsTab.about => [
          item('版本', t('0.1.0')),
          item('说明', t('连信 Linkory — 跨设备即时通信与数据传输。传输链路使用服务端中转，未实现端到端加密。')),
        ],
    };

    return Column(children: [
      PageHeader(title: tab.label),
      Expanded(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 12, 24, 24), children: [
          PanelCard(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Column(children: body)),
        ]),
      ),
    ]);
  }
}

/// A switch with a label whose value lives outside widget state (platform setting).
class _Toggle extends StatefulWidget {
  const _Toggle({required this.label, required this.get, required this.set});
  final String label;
  final Future<bool> Function() get;
  final Future<void> Function(bool) set;
  @override
  State<_Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<_Toggle> {
  bool? _v;
  @override
  void initState() {
    super.initState();
    widget.get().then((v) => mounted ? setState(() => _v = v) : null);
  }

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        LSwitch(
          value: _v ?? false,
          onChanged: _v == null
              ? null
              : (v) async {
                  setState(() => _v = v);
                  await widget.set(v);
                },
        ),
        const SizedBox(width: 10),
        Text(widget.label, style: Type.body.copyWith(color: context.c.text2)),
      ]);
}

class _PasswordDialog extends ConsumerStatefulWidget {
  const _PasswordDialog();
  @override
  ConsumerState<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends ConsumerState<_PasswordDialog> {
  final _old = TextEditingController(), _new = TextEditingController(), _again = TextEditingController();
  String? _err;
  bool _busy = false;

  Future<void> _submit() async {
    if (_new.text != _again.text) return setState(() => _err = '两次输入的新密码不一致');
    if (_new.text.length < 8) return setState(() => _err = '新密码至少 8 位');
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await ref.read(sessionProvider.notifier).changePassword(_old.text, _new.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _err = e.code == 'invalid_credentials' ? '当前密码不正确' : e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LDialog(
      title: '修改密码',
      confirm: _busy ? '提交中…' : '修改',
      onConfirm: _busy ? () {} : _submit,
      body: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        LTextField(controller: _old, hint: '当前密码', obscure: true, autofocus: true),
        const SizedBox(height: 8),
        LTextField(controller: _new, hint: '新密码（至少 8 位）', obscure: true),
        const SizedBox(height: 8),
        LTextField(controller: _again, hint: '再次输入新密码', obscure: true, onSubmitted: (_) => _submit()),
        const SizedBox(height: 8),
        Text('修改后，本账号的其他设备会退出登录。', style: Type.caption.copyWith(color: c.text3)),
        if (_err != null) ...[const SizedBox(height: 6), Text(_err!, style: Type.caption.copyWith(color: c.dangerText))],
      ]),
    );
  }
}
