import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:linkory_app/core/models.dart';
import 'package:linkory_app/core/realtime.dart';
import 'package:linkory_app/core/secrets.dart';
import 'package:linkory_app/core/session.dart';
import 'package:linkory_app/core/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Store with canned data and no network, for widget tests / screenshots.
class FakeStore extends AppStore {
  FakeStore(this.initial);
  final AppState initial;
  final sent = <String>[];

  @override
  AppState build() => initial;
  @override
  Future<void> start() async {}
  @override
  Future<void> refreshAll() async {}
  @override
  Future<void> selectPeer(String id) async => state = state.copyWith(selectedPeer: id, section: Section.chats);
  @override
  String? fileOf(Transfer t) => t.sender == 'mac' ? '/tmp/${t.fileName}' : t.savedPath;
  @override
  Future<void> sendText(String peer, String text, {String type = 'text'}) async => sent.add(text);
}

Future<void> loadTestFonts() async {
  final lucide = Directory('${Platform.environment['HOME']}/.pub-cache/hosted/pub.flutter-io.cn')
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('lucide_icons_flutter-'))
      .map((d) => File('${d.path}/assets/lucide.ttf'))
      .where((f) => f.existsSync())
      .firstOrNull;
  if (lucide != null) {
    final l = FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(Future.value(ByteData.sublistView(lucide.readAsBytesSync())));
    await l.load();
  }
  // Real glyphs (incl. CJK) instead of Ahem boxes so screenshots are readable.
  final f = File('/Library/Fonts/Arial Unicode.ttf');
  if (!f.existsSync()) return;
  final bytes = f.readAsBytesSync();
  for (final family in ['PingFang SC', 'Roboto', '.AppleSystemUIFont']) {
    final l = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await l.load();
  }
}

Device dev(String id, String name, String type, {bool current = false}) => Device(
    id: id, name: name, type: type, osVersion: '14.5', appVersion: '0.1.0', status: 'offline', current: current, lastSeenAt: DateTime(2026, 10, 8, 18, 30));

AppState fixtureState({Section section = Section.chats, String? peer = 'win'}) {
  final now = DateTime(2025, 3, 14, 10, 30); // fixed: goldens must not depend on the wall clock
  return AppState(
    devices: [
      dev('mac', '洪明伟的 MacBook Pro', 'macos', current: true),
      dev('win', '办公室 Windows', 'windows'),
      dev('phone', 'Pixel 9', 'android'),
      dev('lnx', 'Ubuntu 工作站', 'linux'),
    ],
    online: {'win', 'phone'},
    selectedPeer: peer,
    section: section,
    link: LinkState.connected,
    saveDir: '/Users/me/Downloads/Linkory',
    messages: {
      'win': [
        ChatMessage(clientId: '1', peerId: 'win', mine: false, type: 'text', content: '文件我放在共享盘了，你看一下', createdAt: now.subtract(const Duration(minutes: 12))),
        ChatMessage(clientId: '2', peerId: 'win', mine: true, type: 'text', content: '好的，我这边收到了 👍', createdAt: now.subtract(const Duration(minutes: 11)), status: MsgStatus.delivered),
        ChatMessage(clientId: '3', peerId: 'win', mine: true, type: 'clipboard', content: 'https://linkory.example.com/invite/8f3a2c', createdAt: now.subtract(const Duration(minutes: 3)), status: MsgStatus.serverReceived),
        ChatMessage(clientId: '4', peerId: 'win', mine: true, type: 'text', content: '再发一条试试重试', createdAt: now.subtract(const Duration(minutes: 1)), status: MsgStatus.failed),
      ],
      'phone': [ChatMessage(clientId: '5', peerId: 'phone', mine: false, type: 'text', content: '到家了', createdAt: now.subtract(const Duration(days: 1, hours: 2)))],
    },
    transfers: [
      Transfer(id: 't1', sender: 'mac', receiver: 'win', fileName: '季度报表-final.xlsx', size: 4823551, sha256: 'a', status: 'TRANSFERRING', createdAt: now.subtract(const Duration(minutes: 2)), bytes: 2200000),
      Transfer(id: 't2', sender: 'win', receiver: 'mac', fileName: 'design-v7.fig', size: 91234567, sha256: 'b', status: 'WAITING_ACCEPT', createdAt: now.subtract(const Duration(minutes: 1))),
      Transfer(id: 't4', sender: 'win', receiver: 'mac', fileName: '会议纪要.docx', size: 482113, sha256: 'd', status: 'COMPLETED', createdAt: now.subtract(const Duration(minutes: 20)))..savedPath = '/Users/me/Downloads/Linkory/会议纪要.docx',
      Transfer(id: 't3', sender: 'mac', receiver: 'phone', fileName: 'IMG_2031.jpg', size: 3145728, sha256: 'c', status: 'COMPLETED', createdAt: now.subtract(const Duration(hours: 5))),
    ],
  );
}

Future<List<Override>> overrides(AppState s, {AuthStatus auth = AuthStatus.loggedIn}) async {
  SharedPreferences.setMockInitialValues({
    if (auth == AuthStatus.loggedIn) ...{'device_id': 'mac', 'username': 'hongmw'},
  });
  final prefs = await SharedPreferences.getInstance();
  return [
    prefsProvider.overrideWithValue(prefs),
    secretsProvider.overrideWithValue(Secrets.memory(auth == AuthStatus.loggedIn ? {'access': 'a', 'refresh': 'r'} : {})),
    storeProvider.overrideWith(() => FakeStore(s)),
    guestDeviceProvider.overrideWith((_) async => dev('local', '我的 MacBook Pro', 'macos', current: true)),
  ];
}
