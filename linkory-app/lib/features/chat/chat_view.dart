import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/models.dart';
import '../../core/store.dart';
import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../../theme/tokens.dart';
import '../transfers/transfer_card.dart';

/// Right column: conversation with one device.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, required this.peerId});
  final String peerId;
  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (old.peerId != widget.peerId) _focus.requestFocus();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    ref.read(storeProvider.notifier).sendText(widget.peerId, text);
    _input.clear();
    _toBottom();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent + 200, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      });

  Future<void> _sendClipboard() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text ?? '';
    if (t.trim().isEmpty) return;
    ref.read(storeProvider.notifier).sendText(widget.peerId, t, type: 'clipboard');
    _toBottom();
  }

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles();
    for (final f in files) {
      if (f.path != null) await ref.read(storeProvider.notifier).sendFile(widget.peerId, f.path!);
    }
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    final peer = st.device(widget.peerId);
    final online = st.isOnline(widget.peerId);
    ref.listen(storeProvider.select((s) => (s.messages[widget.peerId]?.length ?? 0) + s.transfers.length), (_, _) => _toBottom());

    // Timeline = messages + this pair's file tasks, ordered by time.
    final items = <(DateTime, Object)>[
      for (final m in st.messages[widget.peerId] ?? <ChatMessage>[]) (m.createdAt, m),
      for (final t in st.transfers.where((t) => t.sender == widget.peerId || t.receiver == widget.peerId)) (t.createdAt, t),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    return Column(children: [
      PageHeader(
        title: peer?.name ?? '设备',
        leading: peer == null ? null : DeviceGlyph(type: peer.type, size: 24),
        subtitle: peer == null ? null : '${deviceTypeLabel(peer.type)} · ${online ? '在线' : fmtLastSeen(peer.lastSeenAt)}',
      ),
      Expanded(
        child: items.isEmpty
            ? Center(child: Text('向「${peer?.name ?? '设备'}」发送第一条消息或文件', style: Type.body.copyWith(color: c.text3)))
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final it = items[i];
                  final showTime = i == 0 || it.$1.difference(items[i - 1].$1).inMinutes >= 5;
                  return Column(children: [
                    if (showTime)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(fmtSeparator(it.$1), style: Type.caption.copyWith(color: c.text3)),
                      ),
                    if (it.$2 is ChatMessage)
                      MessageBubble(msg: it.$2 as ChatMessage)
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: TransferCard(task: it.$2 as Transfer)),
                      ),
                  ]);
                },
              ),
      ),
      _Composer(
        controller: _input,
        focus: _focus,
        enabled: peer != null,
        onSend: _send,
        onClipboard: _sendClipboard,
        onFile: _pickFiles,
        online: online,
      ),
    ]);
  }
}

class MessageBubble extends ConsumerWidget {
  const MessageBubble({super.key, required this.msg});
  final ChatMessage msg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final mine = msg.mine;
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine ? c.actionSoft : c.bgCard,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: mine ? c.action.withValues(alpha: .35) : c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (msg.type == 'clipboard')
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(LucideIcons.clipboard, size: 12, color: c.text3),
              const SizedBox(width: 4),
              Text('剪贴板', style: Type.badge.copyWith(color: c.text3)),
            ]),
          ),
        SelectableText(msg.content, style: Type.body.copyWith(color: c.text1, fontSize: 14, height: 1.5)),
      ]),
    );
    final status = switch (msg.status) {
      MsgStatus.sending => ('发送中', c.text3),
      MsgStatus.serverReceived => ('已发送', c.text3),
      MsgStatus.delivered => ('已送达', c.successText),
      MsgStatus.failed => ('发送失败', c.dangerText),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (mine) ...[
            if (msg.status == MsgStatus.failed)
              LIconButton(icon: LucideIcons.rotateCw, tooltip: '重试', onPressed: () => ref.read(storeProvider.notifier).retry(msg)),
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 2),
              child: Text(status.$1, style: Type.badge.copyWith(color: status.$2)),
            ),
          ],
          Flexible(child: bubble),
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: LIconButton(
                  icon: LucideIcons.copy, tooltip: '复制', size: 24, iconSize: 14, onPressed: () => copyText(context, msg.content)),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.onSend,
    required this.onClipboard,
    required this.onFile,
    required this.online,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final bool enabled, online;
  final VoidCallback onSend, onClipboard, onFile;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Container(
        decoration: BoxDecoration(
          color: c.bgCard,
          borderRadius: BorderRadius.circular(Radii.panel),
          border: Border.all(color: c.borderStrong),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(children: [
              LIconButton(icon: LucideIcons.clipboardPaste, tooltip: '发送剪贴板文本', onPressed: enabled ? onClipboard : null),
              LIconButton(icon: LucideIcons.folderOpen, tooltip: online ? '发送文件' : '对方离线，暂不支持离线文件', onPressed: enabled ? onFile : null),
              const Spacer(),
              if (!online) Text('对方离线：文字消息将在其上线后送达', style: Type.caption.copyWith(color: c.text3)),
            ]),
          ),
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): onSend,
            },
            child: SizedBox(
              height: 72,
              child: TextField(
                controller: controller,
                focusNode: focus,
                enabled: enabled,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: Type.body.copyWith(color: c.text1, fontSize: 14),
                cursorColor: c.action,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: '输入消息，Enter 发送，Shift+Enter 换行',
                  hintStyle: Type.body.copyWith(color: c.text3, fontSize: 14),
                  contentPadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              ValueListenableBuilder(
                valueListenable: controller,
                builder: (_, v, _) => LButton(
                    label: '发送', variant: BtnVariant.solid, onPressed: enabled && v.text.trim().isNotEmpty ? onSend : null),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
