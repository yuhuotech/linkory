import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);
  final int status;
  final String code, message;
  @override
  String toString() => '$code: $message';
}

class Tokens {
  Tokens(this.access, this.refresh);
  String access, refresh;
}

/// Thin REST client with transparent access-token refresh (one retry on 401).
class ApiClient {
  ApiClient({required this.baseUrl, this.tokens, this.onTokens, this.onAuthLost, http.Client? client})
      : _http = client ?? http.Client();

  String baseUrl;
  Tokens? tokens;
  final void Function(Tokens)? onTokens;
  final void Function()? onAuthLost;
  final http.Client _http;
  Future<bool>? _refreshing;

  Uri uri(String path, [Map<String, String>? q]) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$base/api/v1$path').replace(queryParameters: q);
  }

  Map<String, String> authHeaders() => {if (tokens != null) 'Authorization': 'Bearer ${tokens!.access}'};

  Future<dynamic> request(String method, String path,
      {Object? body, Map<String, String>? query, bool auth = true, bool retry = true}) async {
    final req = http.Request(method, uri(path, query));
    req.headers['Content-Type'] = 'application/json';
    if (auth) req.headers.addAll(authHeaders());
    if (body != null) req.body = jsonEncode(body);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 15)));
    } on Exception catch (e) {
      throw ApiException(0, 'network', '无法连接服务器：$e');
    }
    if (res.statusCode == 401 && auth && retry && tokens != null) {
      if (await _refresh()) return request(method, path, body: body, query: query, auth: auth, retry: false);
    }
    if (res.statusCode >= 400) {
      try {
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        throw ApiException(res.statusCode, j['code'] ?? 'error', j['message'] ?? '请求失败');
      } on FormatException {
        throw ApiException(res.statusCode, 'error', '请求失败(${res.statusCode})');
      }
    }
    if (res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<bool> _refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final t = tokens;
    if (t == null) return false;
    try {
      final j = await request('POST', '/auth/refresh', body: {'refresh_token': t.refresh}, auth: false, retry: false);
      tokens = Tokens(j['access_token'], j['refresh_token']);
      onTokens?.call(tokens!);
      return true;
    } on ApiException catch (e) {
      if (e.status == 401) {
        tokens = null;
        onAuthLost?.call();
      }
      return false;
    }
  }

  /// Upload/download helpers use raw streams; callers set auth headers themselves.
  http.Client get raw => _http;
}
