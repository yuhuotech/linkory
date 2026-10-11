import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web/browser.dart';

/// Official endpoints are explicit; development/private servers must never be
/// presented as an official service.
class OfficialServer {
  const OfficialServer({required this.name, required this.url, this.aliases = const []});
  final String name, url;
  final List<String> aliases;
  bool matches(String address) => [url, ...aliases].any(
    (candidate) => candidate.replaceFirst(RegExp(r'/+$'), '') == address.replaceFirst(RegExp(r'/+$'), ''));
}

const _defaultOfficialServer = 'https://linkory.yuhuotech.com';
const officialServerUrl = String.fromEnvironment('LINKORY_OFFICIAL_SERVER', defaultValue: _defaultOfficialServer);
const legacyOfficialServerUrl = 'https://linkory.dev99.cn';
const officialServerAliases = officialServerUrl == _defaultOfficialServer
    ? [legacyOfficialServerUrl] : <String>[];

/// Both official domains share the same database/device identity. Other custom
/// servers must remain independent even when their usernames happen to match.
bool sameServerIdentity(String a, String b) {
  String normalize(String url) => url.replaceFirst(RegExp(r'/+$'), '');
  if (normalize(a) == normalize(b)) return true;
  const official = OfficialServer(name: '连信官方', url: officialServerUrl, aliases: officialServerAliases);
  return official.matches(a) && official.matches(b);
}

const officialServerName = String.fromEnvironment(
  'LINKORY_OFFICIAL_SERVER_NAME',
  defaultValue: '连信官方',
);

final officialServersProvider = Provider<List<OfficialServer>>(
  (_) => kIsWeb
      // The page's own server is the "official" one of the browser edition.
      ? [OfficialServer(name: '本站服务', url: browserOrigin())]
      : [
          if (officialServerUrl.isNotEmpty)
            const OfficialServer(
              name: officialServerName,
              url: officialServerUrl,
              aliases: officialServerAliases,
            ),
        ],
);
