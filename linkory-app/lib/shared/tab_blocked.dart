import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/tab_gate.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

/// Shown in a browser tab when another tab of the same browser is already running the session.
class TabBlockedPage extends ConsumerWidget {
  const TabBlockedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    return Scaffold(
      backgroundColor: c.bgSidebar,
      body: Center(
        child: Container(
          width: 380,
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: c.bgCard,
            borderRadius: BorderRadius.circular(Radii.dialog),
            border: Border.all(color: c.border),
            boxShadow: c.shadowLg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const BrandLogo(size: 32),
                const SizedBox(width: 10),
                Expanded(child: Text('连信 Linkory', style: Type.page.copyWith(color: c.text1))),
              ]),
              const SizedBox(height: 16),
              Text('连信已在另一个标签页中打开', style: Type.title.copyWith(color: c.text1)),
              const SizedBox(height: 8),
              Text(
                '同一个浏览器只能在一个标签页里使用连信，否则消息会在两个页面之间互相抢占。你可以关闭这个页面，或者改在这里使用。',
                style: Type.body.copyWith(color: c.text3),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: LButton(
                  label: '在此标签页使用',
                  variant: BtnVariant.solid,
                  onPressed: () => ref.read(tabGateProvider.notifier).takeOver(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
