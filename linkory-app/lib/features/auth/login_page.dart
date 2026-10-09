import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  late final _server = TextEditingController(text: ref.read(sessionProvider).serverUrl);
  late final _user = TextEditingController(text: ref.read(sessionProvider).username);
  final _pass = TextEditingController();
  bool _register = false, _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = ref.read(sessionProvider.notifier);
    try {
      if (_register) await s.register(_server.text, _user.text.trim(), _pass.text);
      await s.login(_server.text, _user.text.trim(), _pass.text);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 14), child: Text(t, style: Type.caption.copyWith(color: c.text2)));
    return Scaffold(
      backgroundColor: c.bgSidebar,
      body: Center(
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: c.bgCard,
            borderRadius: BorderRadius.circular(Radii.dialog),
            border: Border.all(color: c.border),
            boxShadow: c.shadowLg,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: c.action, borderRadius: BorderRadius.circular(8)),
                child: Icon(LucideIcons.link2, size: 18, color: c.actionFg),
              ),
              const SizedBox(width: 10),
              Text('连信 Linkory', style: Type.page.copyWith(color: c.text1)),
            ]),
            const SizedBox(height: 4),
            Text('跨越距离，自由传递。', style: Type.body.copyWith(color: c.text3)),
            label('服务器地址'),
            LTextField(controller: _server, hint: 'http://your-server:8080', prefix: Icon(LucideIcons.server, size: 14, color: c.text3)),
            label('用户名'),
            LTextField(controller: _user, hint: '3-32 个字符', autofocus: true),
            label('密码'),
            LTextField(controller: _pass, hint: '至少 8 位', obscure: true, onSubmitted: (_) => _submit()),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: c.dangerSoft, borderRadius: BorderRadius.circular(Radii.control)),
                  child: Text(_error!, style: Type.caption.copyWith(color: c.dangerText)),
                ),
              ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: Row(children: [
                Expanded(
                  child: LButton(
                      label: _register ? '注册并登录' : '登录',
                      variant: BtnVariant.solid,
                      loading: _busy,
                      onPressed: _submit),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Center(
              child: GestureDetector(
                onTap: () => setState(() => _register = !_register),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Text(_register ? '已有账号？去登录' : '没有账号？注册',
                      style: Type.caption.copyWith(color: c.actionText)),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
