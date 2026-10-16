import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../data/app_database.dart';
import '../../models/account.dart';
import '../../models/login_session.dart';
import '../http_json.dart';

/// WorkBuddy 平台服务：登录状态申请与轮询、token 续期、签到状态与每日签到。
///
/// 线协议对齐 Python 版 `workbuddy_tool.py`，包括 `X-No-Authorization`
/// 这类首次登录所需的特殊请求头。
class WorkBuddyService {
  WorkBuddyService(this._db);

  final AppDatabase _db;

  static const String defaultEndpoint = 'https://www.workbuddy.cn';
  static const String clientVersion = '5.6.2';
  static const String userAgent = 'WorkBuddy/$clientVersion';
  static const String authPrefix = '/v2/plugin';
  static const int pendingTokenCode = 11217;
  static const int pendingAccountCode = 12151;

  // ---------------------------------------------------------------------------
  // 请求头
  // ---------------------------------------------------------------------------

  static String _origin(String endpoint) {
    var value = (endpoint.isEmpty ? defaultEndpoint : endpoint).replaceAll(RegExp(r'/+$'), '');
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.parse(value);
    return '${uri.scheme}://${uri.authority}';
  }

  static Map<String, String> _headers(String endpoint, Map<String, dynamic> account) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'User-Agent': userAgent,
      'X-IDE-Type': 'WorkBuddy',
      'X-IDE-Name': 'WorkBuddy',
      'X-IDE-Version': clientVersion,
      'X-Product': 'WorkBuddy',
      'X-Domain': account['domain']?.toString() ?? Uri.parse(_origin(endpoint)).host,
    };
    final uid = account['uid'];
    if (uid != null && uid.toString().isNotEmpty) {
      headers['X-User-Id'] = uid.toString();
    } else {
      headers.addAll({
        'X-No-User-Id': 'true',
        'X-No-Enterprise-Id': 'true',
        'X-No-Department-Info': 'true',
      });
    }
    final enterpriseId = account['enterpriseId'];
    if (enterpriseId != null && enterpriseId.toString().isNotEmpty) {
      headers['X-Enterprise-Id'] = enterpriseId.toString();
      headers['X-Tenant-Id'] = enterpriseId.toString();
    }
    return headers;
  }

  Future<JsonResult> _request(
    String endpoint,
    String method,
    String path, {
    String? token,
    String? refreshToken,
    Map<String, dynamic> account = const {},
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final headers = _headers(endpoint, account);
    if (method.toUpperCase() == 'POST') {
      headers['Content-Type'] = 'application/json';
    }
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    } else {
      headers['X-No-Authorization'] = 'true';
    }
    if (refreshToken != null && refreshToken.isNotEmpty) {
      headers['X-Refresh-Token'] = refreshToken;
      headers['X-Auth-Refresh-Source'] = 'plugin';
    }
    return HttpJson.send(
      '${_origin(endpoint)}$path',
      method: method,
      headers: headers,
      body: method.toUpperCase() == 'POST' ? (body ?? const {}) : null,
      timeout: timeout,
    );
  }

  // ---------------------------------------------------------------------------
  // 登录
  // ---------------------------------------------------------------------------

  Future<LoginSession> startLogin({
    String endpoint = defaultEndpoint,
    String platform = 'workbuddy',
    String label = '',
    Duration timeout = const Duration(minutes: 10),
    void Function()? onUpdate,
  }) async {
    final result = await _request(
      endpoint,
      'POST',
      '$authPrefix/auth/state?platform=${Uri.encodeQueryComponent(platform)}',
      body: const {},
    );
    final data = result.body['data'];
    if (!result.ok || result.body['code'] != 0 || data is! Map || data['state'] == null || data['authUrl'] == null) {
      throw ApiException(
        '申请登录 state 失败: HTTP ${result.status} code=${result.body['code']} msg=${result.body['msg']}',
      );
    }

    final session = LoginSession(
      id: 'workbuddy-${DateTime.now().microsecondsSinceEpoch}',
      provider: PlatformKind.workbuddy,
      authUrl: data['authUrl'].toString(),
      label: label,
      expiresAt: DateTime.now().add(timeout),
    );
    unawaited(_awaitLogin(session, endpoint, data['state'].toString(), timeout, onUpdate));
    return session;
  }

  Future<void> _awaitLogin(
    LoginSession session,
    String endpoint,
    String state,
    Duration timeout,
    void Function()? onUpdate,
  ) async {
    final deadline = DateTime.now().add(timeout);
    try {
      Map<String, dynamic>? auth;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 1));
        final result = await _request(endpoint, 'GET', '$authPrefix/auth/token?state=${Uri.encodeQueryComponent(state)}');
        final data = result.body['data'];
        if (data is Map && data['accessToken'] != null) {
          auth = _calculateExpiry(data.cast<String, dynamic>());
          break;
        }
        if ((result.body['code'] as num?)?.toInt() != pendingTokenCode) {
          throw ApiException(
            '获取登录令牌失败: HTTP ${result.status} code=${result.body['code']} msg=${result.body['msg']}',
          );
        }
      }
      if (auth == null) throw ApiException('等待登录超时');

      session
        ..status = LoginStatus.exchanging
        ..message = '正在获取账号信息';
      onUpdate?.call();

      Map<String, dynamic> account = const {};
      final accountDeadline = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(accountDeadline) && DateTime.now().isBefore(deadline)) {
        final result = await _request(
          endpoint,
          'GET',
          '$authPrefix/login/account?state=${Uri.encodeQueryComponent(state)}',
          token: auth['accessToken']?.toString(),
          account: {'domain': auth['domain']},
        );
        if ((result.body['code'] as num?)?.toInt() == pendingAccountCode) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (!result.ok || result.body['code'] != 0 || result.body['data'] is! Map) {
          throw ApiException(
            '获取账号失败: HTTP ${result.status} code=${result.body['code']} msg=${result.body['msg']}',
          );
        }
        account = (result.body['data'] as Map).cast<String, dynamic>();
        break;
      }
      if (account.isEmpty) throw ApiException('获取账号失败: 超时');

      final snapshot = await _fetchSnapshot(endpoint, auth);
      account = _chooseAccount(account, snapshot);
      var accountId = account['uid']?.toString() ?? '';
      if (accountId.isEmpty) {
        accountId = 'token-${_sha256Hex(auth['accessToken'].toString()).substring(0, 16)}';
      }
      final displayName = account['nickname']?.toString() ??
          account['displayName']?.toString() ??
          accountId;
      final credential = jsonEncode({'auth': auth, 'account': account, 'snapshot': snapshot});
      final id = await _db.upsertAccount(
        provider: PlatformKind.workbuddy,
        externalId: accountId,
        displayName: displayName,
        endpoint: endpoint,
        credential: credential,
        label: session.label,
      );
      await _db.addLog(id, PlatformKind.workbuddy, action: 'login', ok: true, message: '登录成功', payload: {'display_name': displayName});
      session
        ..status = LoginStatus.success
        ..message = '登录成功'
        ..accountId = id
        ..accountName = displayName;
    } catch (error) {
      session
        ..status = LoginStatus.failed
        ..message = error is ApiException ? error.message : error.toString();
    } finally {
      onUpdate?.call();
    }
  }

  static Map<String, dynamic> _calculateExpiry(Map<String, dynamic> auth) {
    final result = Map<String, dynamic>.from(auth);
    final now = DateTime.now().millisecondsSinceEpoch;
    result.putIfAbsent('lastRefreshTime', () => now);
    if (result['expiresAt'] == null && result['expiresIn'] != null) {
      result['expiresAt'] = now + (int.tryParse(result['expiresIn'].toString()) ?? 0) * 1000;
    }
    if (result['refreshExpiresAt'] == null && result['refreshExpiresIn'] != null) {
      result['refreshExpiresAt'] = now + (int.tryParse(result['refreshExpiresIn'].toString()) ?? 0) * 1000;
    }
    return result;
  }

  static Map<String, dynamic> _chooseAccount(
    Map<String, dynamic> account,
    Map<String, dynamic> snapshot, {
    String? preferUid,
  }) {
    final accounts = (snapshot['accounts'] as List?) ?? const [];
    final allAccounts = (snapshot['allAccounts'] as List?) ?? accounts;
    final candidates = allAccounts.isNotEmpty ? allAccounts : accounts;
    if (preferUid != null) {
      for (final item in candidates) {
        if (item is Map && item['uid']?.toString() == preferUid) {
          return _withoutNulls({...item.cast<String, dynamic>(), ...account});
        }
      }
    }
    if (account.isNotEmpty) return _withoutNulls(account);
    for (final item in candidates) {
      if (item is Map && item['lastLogin'] != null) return Map<String, dynamic>.from(item);
    }
    if (candidates.isNotEmpty && candidates.first is Map) {
      return Map<String, dynamic>.from(candidates.first as Map);
    }
    throw ApiException('服务端未返回可用账号');
  }

  static Map<String, dynamic> _withoutNulls(Map<String, dynamic> source) =>
      {for (final e in source.entries) if (e.value != null) e.key: e.value};

  Future<Map<String, dynamic>> _fetchSnapshot(String endpoint, Map<String, dynamic> auth) async {
    final result = await _request(
      endpoint,
      'GET',
      '$authPrefix/accounts',
      token: auth['accessToken']?.toString(),
    );
    final data = result.body['data'];
    if (result.status != 200 || result.body['code'] != 0 || data is! Map) {
      throw ApiException(
        '获取账号列表失败: HTTP ${result.status} code=${result.body['code']} msg=${result.body['msg']}',
      );
    }
    return data.cast<String, dynamic>();
  }

  // ---------------------------------------------------------------------------
  // 登录态续期
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _refresh(Map<String, Object?> row) async {
    final credential = _credential(row);
    final auth = credential['auth'] as Map<String, dynamic>;
    final refreshToken = auth['refreshToken']?.toString();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw ApiException('没有 refresh_token，请重新登录');
    }
    final endpoint = row['endpoint'] as String;
    final result = await _request(
      endpoint,
      'POST',
      '$authPrefix/auth/token/refresh',
      refreshToken: refreshToken,
      account: {'domain': auth['domain']},
    );
    final data = result.body['data'];
    if (result.status != 200 || result.body['code'] != 0 || data is! Map || data['accessToken'] == null) {
      throw ApiException(
        '刷新登录态失败: HTTP ${result.status} code=${result.body['code']} msg=${result.body['msg']}',
      );
    }
    final newAuth = _calculateExpiry(data.cast<String, dynamic>());
    newAuth['domain'] = newAuth['domain'] ?? auth['domain'];
    final snapshot = await _fetchSnapshot(endpoint, newAuth);
    final account = _chooseAccount(
      (credential['account'] as Map?)?.cast<String, dynamic>() ?? const {},
      snapshot,
      preferUid: row['external_id']?.toString(),
    );
    credential['auth'] = newAuth;
    credential['account'] = account;
    credential['snapshot'] = snapshot;
    await _db.updateCredential(
      row['id'] as int,
      credential: jsonEncode(credential),
      displayName: account['nickname']?.toString() ?? account['displayName']?.toString(),
    );
    return credential;
  }

  static Map<String, dynamic> _credential(Map<String, Object?> row) {
    final decoded = jsonDecode(row['credential'] as String);
    if (decoded is! Map) throw ApiException('账号凭据格式异常');
    return decoded.cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> _ensureFresh(Map<String, Object?> row) async {
    final credential = _credential(row);
    final auth = credential['auth'] as Map<String, dynamic>;
    final expiresAt = auth['expiresAt'];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (auth['refreshToken'] != null &&
        expiresAt != null &&
        now + 60000 >= (int.tryParse(expiresAt.toString()) ?? 0)) {
      return await _refresh(row);
    }
    return credential;
  }

  // ---------------------------------------------------------------------------
  // 用量
  // ---------------------------------------------------------------------------

  static double _number(Object? value) {
    final parsed = double.tryParse(value?.toString() ?? '');
    if (parsed == null) return 0;
    return parsed < 0 ? 0 : parsed;
  }

  static num _clean(double value) =>
      value == value.roundToDouble() ? value.round() : double.parse(value.toStringAsFixed(6));

  static Map<String, dynamic> _parsePersonalUsage(Map<String, dynamic> data) {
    final packages = <Map<String, dynamic>>[];
    var total = 0.0;
    var remain = 0.0;
    var usedTotal = 0.0;
    for (final raw in (data['Packages'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final totalValue = _number(raw['CycleTotalCapacity'] ?? raw['CycleTotal'] ?? raw['CycleCapacitySizePrecise']);
      final remainValue = _number(raw['CycleRemainCapacity'] ?? raw['CycleRemain'] ?? raw['CycleCapacityRemainPrecise']);
      var used = _number(raw['CycleUsedCapacity'] ?? raw['CycleUsed']);
      used = max(used, totalValue - remainValue);
      packages.add({
        'packageCode': raw['PackageCode'] ?? raw['packageCode'] ?? '',
        'total': totalValue,
        'remain': remainValue,
        'used': used,
      });
      total += totalValue;
      remain += remainValue;
      usedTotal += used;
    }
    return {
      'source': 'personal_resource_summary',
      'isPaidUser': data['IsPaidUser'] == true,
      'unlimited': false,
      'creditsTotal': _clean(total),
      'creditsLeft': _clean(remain),
      'creditsUsed': _clean(usedTotal),
      'packages': packages,
    };
  }

  static Map<String, dynamic> _parseEnterpriseUsage(Map<String, dynamic> data) {
    final usage = data['data'] is Map ? (data['data'] as Map).cast<String, dynamic>() : data;
    final totalRaw = usage['limitNum'] ?? usage['limit_num'];
    final usedRaw = usage['credit'] ?? usage['used_num'];
    var total = _number(totalRaw);
    final used = _number(usedRaw);
    final unlimited = totalRaw == -1;
    if (unlimited) {
      total = -1;
    }
    return {
      'source': 'enterprise_user_usage',
      'unlimited': unlimited,
      'creditsTotal': _clean(total),
      'creditsLeft': unlimited ? -1 : _clean(max(0, total - used)),
      'creditsUsed': unlimited ? 0 : _clean(used),
      'packages': <Map<String, dynamic>>[],
    };
  }

  Future<Map<String, dynamic>> _usageRequest(Map<String, Object?> row, Map<String, dynamic> credential) async {
    final account = (credential['account'] as Map).cast<String, dynamic>();
    final auth = (credential['auth'] as Map).cast<String, dynamic>();
    final enterpriseId = account['enterpriseId'] ?? auth['enterpriseId'];
    final path = enterpriseId != null
        ? '/v2/billing/meter/get-enterprise-user-usage'
        : '/billing/meter/get-user-resource-summary';
    final result = await _request(
      row['endpoint'] as String,
      'POST',
      path,
      token: auth['accessToken']?.toString(),
      account: account,
      body: const {},
    );
    if (result.status == 401 || result.status == 403) {
      throw const AuthExpiredException();
    }
    final data = result.body['data'];
    if (result.status != 200 || result.body['code'] != 0 || data is! Map) {
      throw ApiException(
        '查询真实余额失败: HTTP ${result.status} code=${result.body['code']} msg=${result.body['msg']}',
      );
    }
    return enterpriseId != null
        ? _parseEnterpriseUsage(data.cast<String, dynamic>())
        : _parsePersonalUsage(data.cast<String, dynamic>());
  }

  Future<Map<String, dynamic>> _statusRequest(Map<String, Object?> row, Map<String, dynamic> credential) async {
    final account = (credential['account'] as Map).cast<String, dynamic>();
    final auth = (credential['auth'] as Map).cast<String, dynamic>();
    final result = await _request(
      row['endpoint'] as String,
      'POST',
      '/v2/billing/meter/checkin-activity-status',
      token: auth['accessToken']?.toString(),
      account: account,
      body: const {},
    );
    if (result.status == 401 || result.status == 403) {
      throw const AuthExpiredException();
    }
    if (result.status != 200 || result.body['code'] != 0) {
      throw ApiException(
        '查询签到状态失败: HTTP ${result.status} code=${result.body['code']} msg=${result.body['msg']}',
      );
    }
    final data = result.body['data'];
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _claimRequest(Map<String, Object?> row, Map<String, dynamic> credential) async {
    final account = (credential['account'] as Map).cast<String, dynamic>();
    final auth = (credential['auth'] as Map).cast<String, dynamic>();
    final result = await _request(
      row['endpoint'] as String,
      'POST',
      '/v2/billing/meter/daily-checkin',
      token: auth['accessToken']?.toString(),
      account: account,
      body: const {},
    );
    final data = result.body['data'];
    if (result.status == 200 && result.body['code'] == 0 && data is Map) {
      return data.cast<String, dynamic>();
    }
    final code = (result.body['code'] as num?)?.toInt() ?? result.status;
    final message = (result.body['msg'] ?? result.body['message'] ?? '签到失败').toString();
    if (code == 10001 || code == 10002 || message.contains('已签到')) {
      return {'code': code, 'msg': message};
    }
    throw ApiException('签到失败: HTTP ${result.status} code=$code msg=$message');
  }

  static Map<String, dynamic> _mergeUsage(Map<String, dynamic> status, Map<String, dynamic> usage) => {
        ...status,
        'usage': usage,
        'credits_left': usage['creditsLeft'],
        'credits_total': usage['creditsTotal'],
      };

  Future<Map<String, dynamic>> _fetchStatus(Map<String, Object?> row, [Map<String, dynamic>? credential]) async {
    var cred = credential ?? await _ensureFresh(row);
    try {
      final status = await _statusRequest(row, cred);
      final usage = await _usageRequest(row, cred);
      return _mergeUsage(status, usage);
    } on AuthExpiredException {
      cred = await _refresh(row);
      final status = await _statusRequest(row, cred);
      final usage = await _usageRequest(row, cred);
      return _mergeUsage(status, usage);
    }
  }

  Future<Map<String, dynamic>> status(Map<String, Object?> row) async {
    final result = await _fetchStatus(row);
    await _db.updateStatus(row['id'] as int, result);
    return result;
  }

  Future<Map<String, dynamic>> checkin(Map<String, Object?> row) async {
    final initialStatus = await _fetchStatus(row);
    var refreshedRow = await _db.getAccountRow(row['id'] as int) ?? row;
    var credential = _credential(refreshedRow);

    Map<String, dynamic> result;
    if (initialStatus['active'] != true) {
      result = {'action': 'skip', 'ok': true, 'message': '签到活动未开启', 'status': initialStatus};
    } else if (initialStatus['today_checked_in'] == true) {
      result = {'action': 'already', 'ok': true, 'message': '今日已签到', 'status': initialStatus};
    } else {
      Map<String, dynamic> claim;
      try {
        claim = await _claimRequest(refreshedRow, credential);
      } on AuthExpiredException {
        credential = await _refresh(refreshedRow);
        claim = await _claimRequest(refreshedRow, credential);
      }
      final statusAfter = await _statusRequest(refreshedRow, credential);
      final usageAfter = await _usageRequest(refreshedRow, credential);
      result = {
        'action': 'claim',
        'ok': true,
        'message': (claim['msg'] ?? '签到成功').toString(),
        'claim': claim,
        'status': _mergeUsage(statusAfter, usageAfter),
      };
    }

    final statusPayload = (result['status'] as Map?)?.cast<String, dynamic>() ?? initialStatus;
    await _db.updateStatus(row['id'] as int, statusPayload);
    await _db.updateCheckin(row['id'] as int, ok: result['ok'] == true, message: result['message'].toString());
    await _db.addLog(
      row['id'] as int,
      PlatformKind.workbuddy,
      action: result['action'].toString(),
      ok: result['ok'] == true,
      message: result['message'].toString(),
      payload: result,
    );
    return result;
  }

  static String _sha256Hex(String input) {
    // 仅用于给没有 uid 的账号生成稳定 external_id，复用与 Python 一致的 sha256 截断。
    final digest = SHA256Digest().process(Uint8List.fromList(utf8.encode(input)));
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 登录态失效，需要先续期。
class AuthExpiredException implements Exception {
  const AuthExpiredException();

  @override
  String toString() => '登录态无效';
}
