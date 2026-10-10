import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web/browser.dart';

/// Official endpoints are explicit; development/private servers must never be
/// presented as an official service.
class OfficialServer {
  const OfficialServer({required this.name, required this.url});
  final String name, url;
}

const officialServerUrl = String.fromEnvironment(
  'LINKORY_OFFICIAL_SERVER',
  defaultValue: 'https://linkory.dev99.cn',
);
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
            ),
        ],
);
