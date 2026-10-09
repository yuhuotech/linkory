import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/store.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';
import 'transfer_card.dart';

enum TransferFilter { all, active, done, failed }

class TransferFilterNotifier extends Notifier<TransferFilter> {
  @override
  TransferFilter build() => TransferFilter.all;
  void set(TransferFilter f) => state = f;
}

final transferFilterProvider = NotifierProvider<TransferFilterNotifier, TransferFilter>(TransferFilterNotifier.new);

extension TransferFilterX on TransferFilter {
  String get label => switch (this) {
        TransferFilter.all => '全部任务',
        TransferFilter.active => '进行中',
        TransferFilter.done => '已完成',
        TransferFilter.failed => '失败 / 取消',
      };
  IconData get icon => switch (this) {
        TransferFilter.all => LucideIcons.arrowLeftRight,
        TransferFilter.active => LucideIcons.loader,
        TransferFilter.done => LucideIcons.circleCheck,
        TransferFilter.failed => LucideIcons.circleX,
      };
}

class TransfersView extends ConsumerWidget {
  const TransfersView({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final f = ref.watch(transferFilterProvider);
    final all = ref.watch(storeProvider).transfers;
    final list = all.where((t) => switch (f) {
          TransferFilter.all => true,
          TransferFilter.active => t.active,
          TransferFilter.done => t.status == 'COMPLETED',
          TransferFilter.failed => !t.active && t.status != 'COMPLETED',
        }).toList();
    return Column(children: [
      PageHeader(title: '传输中心', subtitle: f.label, actions: [
        LIconButton(icon: LucideIcons.refreshCw, tooltip: '刷新', onPressed: () => ref.read(storeProvider.notifier).loadTransfers()),
      ]),
      Expanded(
        child: list.isEmpty
            ? Center(child: Text('暂无传输任务', style: Type.body.copyWith(color: c.text3)))
            : ListView.separated(
                padding: const EdgeInsets.all(24),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => TransferCard(task: list[i], showPeer: true),
              ),
      ),
    ]);
  }
}
