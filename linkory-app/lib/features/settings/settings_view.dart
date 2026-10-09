import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/session.dart';
import '../../core/store.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

enum SettingsTab { account, transfer, about }

class SettingsTabNotifier extends Notifier<SettingsTab> {
  @override
  SettingsTab build() => SettingsTab.account;
  void set(SettingsTab t) => state = t;
}

final settingsTabProvider = NotifierProvider<SettingsTabNotifier, SettingsTab>(SettingsTabNotifier.new);

extension SettingsTabX on SettingsTab {
  String get label => switch (this) { SettingsTab.account => '账号与安全', SettingsTab.transfer => '传输', SettingsTab.about => '关于' };
  IconData get icon => switch (this) {
        SettingsTab.account => LucideIcons.userRound,
        SettingsTab.transfer => LucideIcons.arrowLeftRight,
        SettingsTab.about => LucideIcons.info,
      };
}

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final tab = ref.watch(settingsTabProvider);
    final sess = ref.watch(sessionProvider);
    final st = ref.watch(storeProvider);

    Widget item(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            SizedBox(width: 120, child: Text(k, style: Type.body.copyWith(color: c.text2))),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: v)),
          ]),
        );
    Text t(String s) => Text(s, style: Type.body.copyWith(color: c.text1));

    final body = switch (tab) {
      SettingsTab.account => [
          item('用户名', t(sess.username)),
          item('服务器', t(sess.serverUrl)),
          item('本机设备 ID', SelectableText(sess.deviceId, style: Type.body.copyWith(color: c.text1))),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: LButton(
                label: '退出登录', icon: LucideIcons.logOut, onPressed: () async {
                  ref.read(storeProvider.notifier).stop();
                  await ref.read(sessionProvider.notifier).logout();
                }),
          ),
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
          item('传输方式', t('公网中转（局域网直连将在后续版本提供）')),
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
