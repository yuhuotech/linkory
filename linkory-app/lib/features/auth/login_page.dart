import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/server_options.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';

/// Sign-in is optional: the app is browsable without it. This opens the form as a dialog.
Future<void> showLogin(BuildContext context, {bool register = false}) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(16),
        child: Center(
          child: SingleChildScrollView(
            child: LoginCard(startInRegister: register, dismissible: true),
          ),
        ),
      ),
    );

/// Stand-alone page variant (kept for tests / deep links).
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.c.bgSidebar,
    body: const Center(child: SingleChildScrollView(child: LoginCard())),
  );
}

class LoginCard extends ConsumerStatefulWidget {
  const LoginCard({
    super.key,
    this.startInRegister = false,
    this.dismissible = false,
  });
  final bool startInRegister, dismissible;
  @override
  ConsumerState<LoginCard> createState() => _LoginCardState();
}

class _LoginCardState extends ConsumerState<LoginCard> {
  late final _server = TextEditingController(
    text: ref.read(sessionProvider).serverUrl,
  );
  late final _user = TextEditingController(
    text: ref.read(sessionProvider).username,
  );
  final _pass = TextEditingController();
  final _confirmPass = TextEditingController();
  final _confirmFocus = FocusNode();
  late bool _register = widget.startInRegister;
  String? _officialUrl;

  @override
  void initState() {
    super.initState();
    final servers = ref.read(officialServersProvider);
    for (final server in servers) {
      if (server.url == _server.text) _officialUrl = server.url;
    }
    if (servers.isNotEmpty && !ref.read(prefsProvider).containsKey('server_url') &&
        !const bool.hasEnvironment('LINKORY_DEFAULT_SERVER')) {
      _officialUrl = servers.first.url;
    }
  }
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    final server = (_officialUrl ?? _server.text).trim();
    final uri = Uri.tryParse(server);
    if (uri == null || !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      setState(() => _error = '请输入完整的服务器地址，例如 https://linkory.example.com');
      return;
    }
    if (_register && (_confirmPass.text.isEmpty || _pass.text != _confirmPass.text)) {
      setState(() => _error = _confirmPass.text.isEmpty
          ? '请再次输入密码'
          : '两次输入的密码不一致，请重新确认');
      _confirmFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = ref.read(sessionProvider.notifier);
    try {
      if (_register) {
        await s.register(server, _user.text.trim(), _pass.text);
      }
      await s.login(server, _user.text.trim(), _pass.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    _confirmPass.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final servers = ref.watch(officialServersProvider);
    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 14),
      child: Text(t, style: Type.caption.copyWith(color: c.text2)),
    );
    // Close the dialog as soon as the session becomes signed in.
    ref.listen(sessionProvider.select((x) => x.status), (_, st) {
      if (st == AuthStatus.loggedIn && widget.dismissible && mounted) {
        Navigator.of(context).maybePop();
      }
    });
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 380,
        constraints: const BoxConstraints(maxWidth: 380),
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
            Row(
              children: [
                const BrandLogo(size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '连信 Linkory',
                    style: Type.page.copyWith(color: c.text1),
                  ),
                ),
                if (widget.dismissible)
                  LIconButton(
                    icon: LucideIcons.x,
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text('跨越距离，自由传递。', style: Type.body.copyWith(color: c.text3)),
            label('服务器'),
            LSelect<String>(
              value: _officialUrl ?? 'custom',
              options: [
                if (servers.isEmpty)
                  const LSelectOption('unavailable', '官方中转服务（暂未开放）', enabled: false),
                for (final server in servers)
                  LSelectOption(server.url, server.name),
                const LSelectOption('custom', '自建服务器'),
              ],
              onChanged: _busy ? null : (value) => setState(() {
                _officialUrl = value == 'custom' ? null : value;
                _error = null;
              }),
            ),
            const SizedBox(height: 8),
            Text(
              _officialUrl != null
                  ? '使用官方中转服务，无需部署或填写地址。'
                  : '连接你或管理员部署的连信服务，请填写完整地址。',
              style: Type.caption.copyWith(color: c.text3),
            ),
            if (_officialUrl == null) ...[
              label('服务器地址'),
              LTextField(
                controller: _server,
                hint: 'https://linkory.example.com',
                prefix: Icon(LucideIcons.server, size: 14, color: c.text3),
              ),
              const SizedBox(height: 8),
              Text('包含 http:// 或 https://，如有端口也需填写。',
                style: Type.caption.copyWith(color: c.text3)),
            ],
            const SizedBox(height: 8),
            Text('所有设备请选择同一服务器；不同服务器的账号不互通。',
              style: Type.caption.copyWith(color: c.text3)),
            label('用户名'),
            LTextField(controller: _user, hint: '3-32 个字符', autofocus: true),
            label('密码'),
            LTextField(
              controller: _pass,
              hint: '至少 8 位',
              obscure: true,
              onSubmitted: (_) => _register ? _confirmFocus.requestFocus() : _submit(),
            ),
            if (_register) ...[
              label('确认密码'),
              LTextField(
                controller: _confirmPass,
                focusNode: _confirmFocus,
                hint: '请再次输入密码',
                obscure: true,
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: c.dangerSoft,
                    borderRadius: BorderRadius.circular(Radii.control),
                  ),
                  child: Text(
                    _error!,
                    style: Type.caption.copyWith(color: c.dangerText),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                LButton(
                  label: _register ? '返回登录' : '注册账号',
                  variant: BtnVariant.ghost,
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _register = !_register;
                          _error = null;
                          _confirmPass.clear();
                        }),
                ),
                const Spacer(),
                SizedBox(
                  width: 120,
                  child: LButton(
                    label: _register ? '注册并登录' : '登录',
                    icon: _register ? LucideIcons.userPlus : LucideIcons.logIn,
                    variant: BtnVariant.solid,
                    loading: _busy,
                    onPressed: _submit,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
