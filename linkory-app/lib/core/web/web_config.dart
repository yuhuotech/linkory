import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Browser edition: may this page also sign in to servers other than the one that served it? The serving server
/// decides (LINKORY_WEB_ALLOW_CUSTOM_SERVER); when it does not say, the answer is no.
bool webCustomServerAllowed = false;

Future<void> loadWebConfig() async {
  if (!kIsWeb) return;
  try {
    final r = await http.get(Uri.base.resolve('web-config.json')).timeout(const Duration(seconds: 5));
    if (r.statusCode == 200) webCustomServerAllowed = r.body.contains('"custom_server":true');
  } catch (_) {}
}
