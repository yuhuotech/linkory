import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
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
  final _query = TextEditingController();
  bool _searching = false;
  bool _dragging = false;

  @override
  void dispose() {
    _input.dispose();
    _query.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (old.peerId != widget.peerId) {
      _focus.requestFocus();
      _query.clear();
      _searching = false;
    }
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
    await ref.read(storeProvider.notifier).sendFiles(widget.peerId, files.map((f) => f.path).whereType<String>());
    _toBottom();
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
          title: '清空聊天记录', message: '只清除本机显示的记录，不会影响对方设备，也不会删除已保存的文件。', confirmLabel: '清空', destructive: true),
    );
    if (ok == true) await ref.read(storeProvider.notifier).clearConversation(widget.peerId);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = ref.watch(storeProvider);
    final peer = st.device(widget.peerId);
    final online = st.isOnline(widget.peerId);
    ref.listen(storeProvider.select((s) => (s.messages[widget.peerId]?.length ?? 0) + s.transfers.length), (_, _) => _toBottom());

    // Timeline = messages + this pair's file tasks, ordered by time.
    final q = _query.text.trim().toLowerCase();
    final items = <(DateTime, Object)>[
      for (final m in st.messages[widget.peerId] ?? <ChatMessage>[])
        if (q.isEmpty || m.content.toLowerCase().contains(q)) (m.createdAt, m),
      if (q.isEmpty)
        for (final t in st.transfers.where((t) => t.sender == widget.peerId || t.receiver == widget.peerId)) (t.createdAt, t),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    final body = Column(children: [
      PageHeader(
        title: peer?.name ?? '设备',
        leading: peer == null ? null : DeviceGlyph(type: peer.type, size: 24),
        subtitle: peer == null ? null : '${deviceTypeLabel(peer.type)} · ${online ? '在线' : fmtLastSeen(peer.lastSeenAt)}',
        actions: [
          LIconButton(
              icon: LucideIcons.search,
              tooltip: '搜索消息',
              onPressed: () => setState(() {
                    _searching = !_searching;
                    if (!_searching) _query.clear();
                  })),
          LIconButton(icon: LucideIcons.trash2, tooltip: '清空聊天记录', onPressed: _clear),
        ],
      ),
      if (_searching)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 16, 0),
          child: LTextField(controller: _query, hint: '搜索此会话的消息', autofocus: true, onChanged: (_) => setState(() {})),
        ),
      Expanded(
        child: items.isEmpty
            ? Center(
                child: Text(q.isNotEmpty ? '没有匹配的消息' : '向「${peer?.name ?? '设备'}」发送第一条消息或文件，也可以把文件拖到这里',
                    style: Type.body.copyWith(color: c.text3)))
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
                      Align(
                        // Like bubbles: files I send on the right, files I receive on the left.
                        alignment: (it.$2 as Transfer).sender == widget.peerId ? Alignment.centerLeft : Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: TransferCard(task: it.$2 as Transfer)),
                        ),
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

    // PRD FILE-010: drop files anywhere on the conversation.
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        ref.read(storeProvider.notifier).sendFiles(widget.peerId, d.files.map((f) => f.path));
      },
      child: Stack(children: [
        body,
        if (_dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.actionSoft.withValues(alpha: .9),
                  borderRadius: BorderRadius.circular(Radii.dialog),
                  border: Border.all(color: c.action, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text('松开以发送给「${peer?.name ?? '设备'}」', style: Type.section.copyWith(color: c.actionText)),
              ),
            ),
          ),
      ]),
    );
  }
}

class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({super.key, required this.msg});
  final ChatMessage msg;
  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
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
    // MSG-007 copy / MSG-009 delete the local record; shown on hover to keep the stream calm.
    final actions = Opacity(
      opacity: _hover ? 1 : 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          LIconButton(icon: LucideIcons.copy, tooltip: '复制', size: 24, iconSize: 14, onPressed: () => copyText(context, msg.content)),
          LIconButton(
              icon: LucideIcons.trash2,
              tooltip: '删除本地记录',
              size: 24,
              iconSize: 14,
              onPressed: () => ref.read(storeProvider.notifier).deleteMessage(msg)),
        ]),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Row(
          mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (mine) ...[
              actions,
              if (msg.status == MsgStatus.failed)
                LIconButton(icon: LucideIcons.rotateCw, tooltip: '重试', onPressed: () => ref.read(storeProvider.notifier).retry(msg)),
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 2),
                child: Text(status.$1, style: Type.badge.copyWith(color: status.$2)),
              ),
            ],
            Flexible(child: bubble),
            if (!mine) actions,
          ],
        ),
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
