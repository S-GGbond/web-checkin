import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 平台接口调用失败。
class ApiException implements Exception {
  ApiException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// 一次 JSON 请求的结果。与 Python 版一致：HTTP 非 2xx 不抛异常，
/// 而是把响应体尽量解析成 JSON 一并返回，交由调用方判读业务 code。
class JsonResult {
  const JsonResult(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status >= 200 && status < 300;
}

class HttpJson {
  HttpJson._();

  static final http.Client _client = http.Client();

  static Future<JsonResult> send(
    String url, {
    String method = 'POST',
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = Uri.parse(url);
    final request = http.Request(method.toUpperCase(), uri);
    if (headers != null) {
      request.headers.addAll(headers);
    }
    if (body != null) {
      // 紧凑分隔符，与 Python json.dumps(separators=(",", ":")) 对齐。
      request.body = body is String ? body : jsonEncode(body);
    }

    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw ApiException('请求超时: ${uri.host}${uri.path}');
    } catch (error) {
      throw ApiException('请求失败: ${uri.host}${uri.path}: $error');
    }

    Map<String, dynamic> parsed;
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    try {
      final decoded = jsonDecode(text.isEmpty ? '{}' : text);
      parsed = decoded is Map<String, dynamic> ? decoded : {'data': decoded};
    } catch (_) {
      parsed = {'message': text.isEmpty ? 'HTTP ${response.statusCode}' : text};
    }
    return JsonResult(response.statusCode, parsed);
  }
}
