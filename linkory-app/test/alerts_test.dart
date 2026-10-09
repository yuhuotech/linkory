import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linkory_app/core/models.dart';
import 'package:linkory_app/core/notifications.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Recorder implements SystemNotifier {
  final shown = <({String peer, String title, String body, int count})>[];
  final cleared = <String>[];
  int unread = 0;
  @override
  Future<void> show({required String peerId, required String title, required String body, required int count}) async =>
      shown.add((peer: peerId, title: title, body: body, count: count));
  @override
  Future<void> clear(String peerId) async => cleared.add(peerId);
  @override
  Future<void> setUnread(int total) async => unread = total;
}

Map<String, dynamic> msg(String from, String text, {String type = 'text', String? id}) => {
      'id': 'srv-${id ?? text}',
      'client_msg_id': 'c-${id ?? text}',
      'from_device_id': from,
      'to_device_id': 'me',
      'type': type,
      'content': text,
      'created_at': '2026-10-09T10:00:00Z',
    };

Device dev(String id, String name) => Device(id: id, name: name, type: 'linux', osVersion: '', appVersion: '', status: 'online', current: false);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 750)); // alert debounce is 600ms

void main() {
  late SharedPreferences prefs;
  late Recorder sys;
  late ProviderContainer c;
  late AppStore store;

  Future<void> boot({Map<String, Object> initial = const {}}) async {
    SharedPreferences.setMockInitialValues(initial);
    prefs = await SharedPreferences.getInstance();
    sys = Recorder();
    c = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), systemNotifierProvider.overrideWithValue(sys)]);
    addTearDown(c.dispose);
    store = c.read(storeProvider.notifier);
    store.debugSet(c.read(storeProvider).copyWith(devices: [dev('a', '办公室'), dev('b', '手机')]));
  }

  void view(String? peer, {Section section = Section.chats}) =>
      store.debugSet(c.read(storeProvider).copyWith(selectedPeer: peer, section: section));
  AppState st() => c.read(storeProvider);

  test('the conversation on screen in the front window is simply read: no unread, no banner, no notification', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(true);
    view('a');
    store.debugEvent('message.receive', msg('a', 'hello'));
    await settle();
    expect(st().unread, isEmpty);
    expect(c.read(toastProvider), isNull);
    expect(sys.shown, isEmpty);
  });

  test('front window but another conversation: unread + an in-app banner, no system notification', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(true);
    view('a');
    store.debugEvent('message.receive', msg('b', '在吗'));
    await settle();
    expect(st().unread, {'b': 1});
    expect(c.read(toastProvider)?.title, '手机');
    expect(c.read(toastProvider)?.body, '在吗');
    expect(sys.shown, isEmpty);
    expect(sys.unread, 1, reason: 'Dock / launcher badge follows the total');
  });

  test('window in the background: a system notification, even for the conversation that is selected', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(false);
    view('a');
    store.debugEvent('message.receive', msg('a', '文件发你了'));
    await settle();
    expect(st().unread, {'a': 1});
    expect(sys.shown.single.title, '办公室');
    expect(sys.shown.single.body, '文件发你了');
    expect(c.read(toastProvider), isNull);
  });

  test('a burst becomes one notification per conversation, carrying the count', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(false);
    for (final t in ['1', '2', '3']) {
      store.debugEvent('message.receive', msg('a', 'm$t'));
    }
    store.debugEvent('message.receive', msg('b', 'x'));
    await settle();
    expect(sys.shown.where((n) => n.peer == 'a'), hasLength(1));
    expect(sys.shown.firstWhere((n) => n.peer == 'a').count, 3);
    expect(sys.shown.firstWhere((n) => n.peer == 'a').body, 'm3', reason: 'latest message is shown');
    expect(sys.shown.where((n) => n.peer == 'b'), hasLength(1));
    expect(st().totalUnread, 4);
  });

  test('coming back to the window reads the open conversation and removes its notification', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(false);
    view('a');
    store.debugEvent('message.receive', msg('a', 'hi'));
    store.debugEvent('message.receive', msg('b', 'yo'));
    await settle();
    expect(st().totalUnread, 2);
    c.read(appActiveProvider.notifier).set(true); // user focuses the window; conversation a is open
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(st().unread, {'b': 1}, reason: 'only the visible conversation is read');
    expect(sys.cleared, contains('a'));
    expect(sys.unread, 1);
  });

  test('opening a conversation reads it; other sections do not count as looking at a chat', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(true);
    view('a', section: Section.settings);
    store.debugEvent('message.receive', msg('a', 'hello'));
    await settle();
    expect(st().unread, {'a': 1}, reason: 'the settings page is not the conversation');
    await store.openConversation('a');
    expect(st().unread, isEmpty);
    expect(c.read(toastProvider), isNull);
  });

  test('notifications off: still counted as unread (badge), but nothing pops up', () async {
    await boot(initial: {'notify_enabled': false});
    c.read(appActiveProvider.notifier).set(false);
    store.debugEvent('message.receive', msg('a', 'quiet'));
    await settle();
    expect(st().unread, {'a': 1});
    expect(sys.shown, isEmpty);
    expect(c.read(toastProvider), isNull);
  });

  test('preview off: the notification does not reveal the message', () async {
    await boot(initial: {'notify_preview': false});
    c.read(appActiveProvider.notifier).set(false);
    store.debugEvent('message.receive', msg('a', '密码是 hunter2'));
    await settle();
    expect(sys.shown.single.body, '发来一条新消息');
    expect(sys.shown.single.body, isNot(contains('hunter2')));
  });

  test('clipboard messages are labelled; duplicates (a re-delivered message) do not count twice', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(false);
    store.debugEvent('message.receive', msg('a', 'https://x.y', type: 'clipboard', id: 'one'));
    store.debugEvent('message.receive', msg('a', 'https://x.y', type: 'clipboard', id: 'one'));
    await settle();
    expect(st().unread, {'a': 1});
    expect(sys.shown.single.body, startsWith('[剪贴板]'));
  });

  test('an incoming file is announced when it has arrived (auto-accept) and counts as unread', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(false);
    store.debugEvent('transfer.complete', {
      'id': 't1',
      'sender_device_id': 'a',
      'receiver_device_id': '', // this device (no session in the test)
      'file_name': '报告.pdf',
      'size': 10,
      'sha256': 'x',
      'status': 'COMPLETED',
      'created_at': '2026-10-09T10:00:00Z',
    });
    await settle();
    expect(st().unread, {'a': 1});
    expect(sys.shown.single.body, '[文件] 报告.pdf');
  });

  test('unread counts survive a restart', () async {
    await boot();
    c.read(appActiveProvider.notifier).set(false);
    store.debugEvent('message.receive', msg('a', 'later'));
    await settle();
    expect(prefs.getString('unread_counts'), contains('"a":1'));
    final c2 = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs), systemNotifierProvider.overrideWithValue(Recorder())]);
    addTearDown(c2.dispose);
    expect(c2.read(storeProvider).unread, {'a': 1});
  });
}
