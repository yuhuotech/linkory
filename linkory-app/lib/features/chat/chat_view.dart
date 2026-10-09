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
import 'message_bubble.dart';

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
  bool _showLatest = false; // scrolled away from the newest messages

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final away = _scroll.offset > 240; // the list is reversed: offset 0 is the newest message
      if (away != _showLatest) setState(() => _showLatest = away);
    });
  }

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
        if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
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
    ref.listen(storeProvider.select((s) => (s.messages[widget.peerId]?.length ?? 0) + s.transfers.length), (_, _) {
      // Follow new messages only when already reading the latest; don't yank someone reading history.
      if (!_showLatest) _toBottom();
    });

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
            ? (q.isNotEmpty
                ? Center(child: Text('没有匹配的消息', style: Type.body.copyWith(color: c.text3)))
                : _EmptyConversation(peer: peer, online: online, onFile: _pickFiles, onClipboard: _sendClipboard))
            : LayoutBuilder(builder: (context, box) {
                // Bubbles take up to 70% of the pane (never wider than 640) so long lines stay readable.
                final maxBubble = (box.maxWidth * .7).clamp(280.0, 640.0);
                String key(Object o) => o is ChatMessage ? (o.mine ? 'me' : 'peer') : ((o as Transfer).sender == widget.peerId ? 'peer' : 'me');
                bool gap(DateTime a, DateTime b) => b.difference(a).inMinutes >= 5;
                return Stack(children: [
                  ListView.builder(
                    controller: _scroll,
                    reverse: true, // anchored to the newest message, like every chat app
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    itemCount: items.length,
                    itemBuilder: (_, ri) {
                      final i = items.length - 1 - ri;
                      final it = items[i];
                      final showTime = i == 0 || gap(items[i - 1].$1, it.$1);
                      final first = showTime || key(items[i - 1].$2) != key(it.$2);
                      final last = i == items.length - 1 || gap(it.$1, items[i + 1].$1) || key(items[i + 1].$2) != key(it.$2);
                      final isPeer = key(it.$2) == 'peer';
                      return Column(children: [
                        if (showTime)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Row(children: [
                              Expanded(child: Divider(color: c.border, height: 1)),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: Text(fmtDaySeparator(it.$1), style: Type.caption.copyWith(color: c.text3)),
                              ),
                              Expanded(child: Divider(color: c.border, height: 1)),
                            ]),
                          ),
                        if (it.$2 is ChatMessage)
                          MessageBubble(msg: it.$2 as ChatMessage, first: first, last: last, peer: peer, maxWidth: maxBubble)
                        else
                          Padding(
                            padding: EdgeInsets.only(top: first ? 10 : 2),
                            child: Row(
                              mainAxisAlignment: isPeer ? MainAxisAlignment.start : MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (isPeer) PeerAvatar(peer: peer, show: first),
                                Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 340), child: TransferCard(task: it.$2 as Transfer))),
                              ],
                            ),
                          ),
                      ]);
                    },
                  ),
                  if (_showLatest)
                    Positioned(
                      right: 20,
                      bottom: 8,
                      child: Container(
                        decoration: BoxDecoration(color: c.bgCard, shape: BoxShape.circle, border: Border.all(color: c.border), boxShadow: c.shadowMd),
                        child: LIconButton(icon: LucideIcons.arrowDown, tooltip: '回到最新', size: 32, iconSize: 16, onPressed: _toBottom),
                      ),
                    ),
                ]);
              }),
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

/// A conversation with no messages yet: who this device is, and the two things you can do here.
class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.peer, required this.online, required this.onFile, required this.onClipboard});
  final Device? peer;
  final bool online;
  final VoidCallback onFile, onClipboard;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = peer;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (p != null) DeviceGlyph(type: p.type, size: 56, online: online),
          const SizedBox(height: 14),
          Text(p?.name ?? '设备', style: Type.section.copyWith(color: c.text1)),
          const SizedBox(height: 4),
          Text(
            p == null ? '' : '${deviceTypeLabel(p.type)}${p.osVersion.isEmpty ? '' : ' · ${p.osVersion}'}',
            style: Type.caption.copyWith(color: c.text3),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          LBadge(online ? '在线' : '离线', bg: online ? c.successSoft : c.bgSubtle, fg: online ? c.successText : c.text2),
          const SizedBox(height: 18),
          Text('还没有消息。发送文字，或者把文件拖到这里。', style: Type.body.copyWith(color: c.text3)),
          const SizedBox(height: 14),
          Row(mainAxisSize: MainAxisSize.min, children: [
            LButton(label: '发送文件', icon: LucideIcons.folderOpen, onPressed: onFile),
            const SizedBox(width: 8),
            LButton(label: '发送剪贴板', icon: LucideIcons.clipboardPaste, onPressed: onClipboard),
          ]),
        ]),
      ),
    );
  }
}
