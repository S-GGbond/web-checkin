import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/app_database.dart';
import '../../models/account.dart';
import '../../models/login_session.dart';
import '../../models/usage_record.dart';
import '../../util/app_paths.dart';
import '../http_json.dart';
import 'qoder_desktop.dart';
import 'qoder_web_usage.dart';

/// Qoder 平台服务：设备码登录、状态（额度/套餐）、签到（领取 Credits 活动）与用量。
///
/// 与 qoder-checkin 脚本同一套协议：
/// - 业务请求带 `Bearer` + `Cosy-ClientType/Version`；
/// - 401 时用 `/api/v1/deviceToken/refresh` 续期，refresh_token 会轮换；
/// - 签到 = 领取 actionType 为 CLAIM_BENEFIT 的 campaign，领取后查 reward 才是发放依据。
class QoderService {
  QoderService(this._db);

  final AppDatabase _db;

  /// 网页端用量明细（浏览器登录态 + qoder.cn 接口）。
  late final QoderWebUsage _web = QoderWebUsage(_db);

  static const openapi = 'https://openapi.qoder.com.cn';
  static const authBase = 'https://qoder.cn';
  static const clientId = '732aef47-9cf2-46a2-95fe-4cebb5d0d1fa';
  static const clientType = '10';
  static const clientVersion = '0.3.4';

  // ---------------------------------------------------------------------------
  // 凭据与请求
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _machineIdentity() async {
    final file = File(p.join(AppPaths.home, '.qoder-identity.json'));
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && (decoded['machineId']?.toString().isNotEmpty ?? false)) {
          return decoded.cast<String, dynamic>();
        }
      }
    } catch (_) {
      // 文件损坏时重建。
    }
    final rng = Random.secure();
    final id = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final identity = {'machineId': id};
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(identity));
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', file.path]);
      }
    } catch (_) {
      // 写不进去也不影响本次登录。
    }
    return identity;
  }

  static String _machineOs() {
    final version = Platform.version.toLowerCase();
    final arch = version.contains('aarch64') || version.contains('arm64')
        ? 'aarch64'
        : 'x86_64';
    return '${arch}_${Platform.operatingSystem}';
  }

  static Map<String, String> _headers({String? token, String? machineId}) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'User-Agent': 'Qoder',
      'Cosy-ClientType': clientType,
      'Cosy-Version': clientVersion,
      'Cosy-MachineOS': _machineOs(),
    };
    if (machineId != null && machineId.isNotEmpty) {
      headers['Cosy-MachineId'] = machineId;
    }
    final host = Platform.localHostname;
    if (host.isNotEmpty && host.length <= 96) {
      headers['Cosy-MachineHostname'] = host;
    }
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Map<String, dynamic> _credential(Map<String, Object?> row) {
    final decoded = jsonDecode(row['credential'] as String);
    if (decoded is! Map) throw ApiException('账号凭据格式异常');
    return decoded.cast<String, dynamic>();
  }

  Future<void> _save(Map<String, Object?> row, Map<String, dynamic> auth) async {
    await _db.updateCredential(row['id'] as int, credential: jsonEncode(auth));
  }

  /// 续期：refresh_token 轮换，必须回写。
  Future<void> _refresh(Map<String, Object?> row, Map<String, dynamic> auth) async {
    final refreshToken = auth['refreshToken']?.toString() ?? '';
    if (refreshToken.isEmpty) {
      throw ApiException('Qoder 登录态缺少 refresh_token，请重新登录');
    }
    final result = await HttpJson.send(
      '$openapi/api/v1/deviceToken/refresh',
      method: 'POST',
      headers: const {
        'Accept': 'application/json',
        'User-Agent': 'Qoder',
        'Content-Type': 'application/json',
      },
      body: {'refresh_token': refreshToken},
    );
    if (result.status != 200) {
      throw ApiException('Qoder 登录续期失败: HTTP ${result.status}');
    }
    final token = (result.body['device_token'] ?? result.body['token'])?.toString() ?? '';
    if (token.isEmpty) throw ApiException('Qoder 续期没有返回 token');
    auth['token'] = token;
    auth['refreshToken'] = result.body['refresh_token']?.toString() ?? refreshToken;
    auth['expiresAt'] = _expiryOf(result.body, 'expires_at', 'expires_in');
    auth['refreshTokenExpiresAt'] = _expiryOf(
      result.body,
      'refresh_token_expires_at',
      'refresh_token_expires_in',
    );
    await _save(row, auth);
  }

  Future<Map<String, dynamic>> _load(Map<String, Object?> row) async {
    final auth = _credential(row);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final refreshExpiry = (auth['refreshTokenExpiresAt'] as num?)?.toInt() ?? 0;
    if (refreshExpiry > 0 && now >= refreshExpiry) {
      throw ApiException('Qoder 登录已过期，请重新登录');
    }
    final expiresAt = (auth['expiresAt'] as num?)?.toInt() ?? 0;
    if (expiresAt == 0 || now >= expiresAt - 60) {
      await _refresh(row, auth);
    }
    return auth;
  }

  static int _expiryOf(Map<String, dynamic> body, String atKey, String inKey) {
    final at = body[atKey];
    if (at != null) {
      if (at is num) {
        var value = at.toDouble();
        if (value > 1e12) value /= 1000;
        return value.toInt();
      }
      final parsed = DateTime.tryParse(at.toString().replaceFirst('Z', '+00:00'));
      if (parsed != null) return parsed.millisecondsSinceEpoch ~/ 1000;
    }
    final seconds = body[inKey];
    if (seconds is num) {
      return DateTime.now().millisecondsSinceEpoch ~/ 1000 + seconds.toInt();
    }
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;
  }

  Future<Map<String, dynamic>> _json(
    Map<String, Object?> row,
    Map<String, dynamic> auth,
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    Future<JsonResult> send() => HttpJson.send(
          '$openapi$path',
          method: method,
          headers: {
            ..._headers(
              token: auth['token']?.toString(),
              machineId: auth['machineId']?.toString(),
            ),
            if (body != null) 'Content-Type': 'application/json',
          },
          body: body,
        );

    var result = await send();
    if (result.status == 401) {
      await _refresh(row, auth);
      result = await send();
    }
    if (result.status != 200) {
      throw ApiException('Qoder 请求失败: HTTP ${result.status}');
    }
    return result.body;
  }

  // ---------------------------------------------------------------------------
  // 登录（设备码 + PKCE）
  // ---------------------------------------------------------------------------

  Future<LoginSession> startLogin({
    String label = '',
    Duration timeout = const Duration(minutes: 5),
    void Function()? onUpdate,
  }) async {
    final identity = await _machineIdentity();
    final machineId = identity['machineId'].toString();
    final verifier = _randomString(64);
    final challenge = _codeChallenge(verifier);
    final nonce = _uuid();

    final inner = Uri(queryParameters: {
      'challenge': challenge,
      'challenge_method': 'S256',
      'nonce': nonce,
      'machine_id': machineId,
      'client_id': clientId,
    }).query;
    final selectUrl = '$authBase/device/selectAccounts?$inner';
    final outer = Uri(queryParameters: {
      'biz_variant': 'qoder',
      'oauth_callback': selectUrl,
    }).query;

    final session = LoginSession(
      id: 'qoder-${DateTime.now().microsecondsSinceEpoch}',
      provider: PlatformKind.qoder,
      authUrl: '$authBase/users/sign-in?$outer',
      label: label,
      expiresAt: DateTime.now().add(timeout),
    );
    unawaited(_awaitToken(session, verifier, nonce, machineId, timeout, onUpdate));
    return session;
  }

  Future<void> _awaitToken(
    LoginSession session,
    String verifier,
    String nonce,
    String machineId,
    Duration timeout,
    void Function()? onUpdate,
  ) async {
    final query = Uri(queryParameters: {
      'nonce': nonce,
      'verifier': verifier,
      'challenge_method': 'S256',
    }).query;
    final url = '$openapi/api/v1/deviceToken/poll?$query';
    final deadline = DateTime.now().add(timeout);
    var failures = 0;
    try {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (session.isTerminal) return;
        try {
          final result = await HttpJson.send(
            url,
            method: 'GET',
            headers: const {'Accept': 'application/json', 'User-Agent': 'Qoder'},
          );
          failures = 0;
          final token = result.body['token']?.toString() ?? '';
          final refresh = result.body['refresh_token']?.toString() ?? '';
          if (result.status == 200 && token.isNotEmpty && refresh.isNotEmpty) {
            session
              ..status = LoginStatus.exchanging
              ..message = '正在获取账号信息';
            onUpdate?.call();

            final user = await _userInfo(token);
            final auth = <String, dynamic>{
              'schemaVersion': 1,
              'token': token,
              'refreshToken': refresh,
              'expiresAt': _expiryOf(result.body, 'expires_at', 'expires_in'),
              'refreshTokenExpiresAt': _expiryOf(
                result.body,
                'refresh_token_expires_at',
                'refresh_token_expires_in',
              ),
              'machineId': machineId,
              'user': user,
              'savedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            };
            final uid = _userIdOf(auth);
            if (uid.isEmpty) throw ApiException('Qoder 未返回用户 ID');
            final name = _userNameOf(auth);
            final id = await _db.upsertAccount(
              provider: PlatformKind.qoder,
              externalId: uid,
              displayName: name.isEmpty ? uid : name,
              endpoint: openapi,
              credential: jsonEncode(auth),
              label: session.label,
            );
            await _db.addLog(
              id,
              PlatformKind.qoder,
              action: 'login',
              ok: true,
              message: '登录成功',
              payload: {'display_name': name},
            );
            session
              ..status = LoginStatus.success
              ..message = '登录成功'
              ..accountId = id
              ..accountName = name;
            onUpdate?.call();
            // 浏览器里刚完成的就是这个账号的登录，顺手把网页登录态抓下来绑到账号上，
            // 之后「用量明细」不用再让浏览器保持登录。
            unawaited(_web.captureForAccount(id, uid));
            return;
          }
        } catch (error) {
          failures++;
          if (failures >= 5) rethrow;
        }
      }
      throw ApiException('Qoder 登录超时');
    } catch (error) {
      session
        ..status = LoginStatus.failed
        ..message = error is ApiException ? error.message : '$error';
      onUpdate?.call();
    }
  }

  Future<Map<String, dynamic>> _userInfo(String token) async {
    final result = await HttpJson.send(
      '$openapi/api/v1/userinfo',
      method: 'GET',
      headers: _headers(token: token),
    );
    return result.status == 200 ? result.body : <String, dynamic>{};
  }

  // ---------------------------------------------------------------------------
  // 状态
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> status(Map<String, Object?> row) async {
    final auth = await _load(row);
    final usage = await _json(row, auth, '/sash/api/v2/me/usage');
    final plan = await _json(row, auth, '/api/v2/user/plan');

    final q = (usage['qoderUsage'] as Map?)?.cast<String, dynamic>() ?? const {};
    final quota = (q['userQuota'] as Map?)?.cast<String, dynamic>() ?? const {};
    final addon = (q['addOnQuota'] as Map?)?.cast<String, dynamic>() ?? const {};
    final total = _num(quota['total']) + _num(addon['total']);
    final left = _num(quota['remaining']) + _num(addon['remaining']);
    final used = _num(quota['used']) + _num(addon['used']);
    final org = (plan['organization'] as Map?)?.cast<String, dynamic>() ?? const {};
    final checked = await _grantedToday(row, auth);

    return {
      'source': 'qoder_usage',
      'active': true,
      'checked_in': checked,
      'usage': {
        'creditsTotal': total,
        'creditsLeft': left,
        'creditsUsed': used,
        'unlimited': false,
      },
      'plan': {
        'tier': plan['plan_tier_name'] ?? plan['planTierName'] ?? '',
        'userType': plan['user_type'] ?? plan['userType'] ?? '',
        'organization': org['name'] ?? org['org_name'] ?? '',
        'quotaPercentage': q['totalUsagePercentage'] ?? 0,
      },
    };
  }

  Future<bool> _grantedToday(
    Map<String, Object?> row,
    Map<String, dynamic> auth,
  ) async {
    try {
      final data = await _json(row, auth, '/sash/api/v1/me/campaigns');
      final campaigns = (data['campaigns'] as List?) ?? const [];
      final today = _today();
      for (final item in campaigns) {
        if (item is! Map || !_isCreditCampaign(item)) continue;
        if (item['claimStatus'] != 'CLAIMED') continue;
        final id = item['campaignId']?.toString() ?? '';
        if (id.isEmpty) continue;
        final reward = await _json(
          row,
          auth,
          '/sash/api/v1/me/campaigns/$id/reward',
        );
        if (_localDate(reward['claimedAt']) == today) return true;
      }
    } catch (_) {
      // 活动查询失败时按未签到处理，不影响额度展示。
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 签到
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> checkin(Map<String, Object?> row) async {
    final auth = await _load(row);
    Map<String, dynamic> result;
    try {
      final data = await _json(row, auth, '/sash/api/v1/me/campaigns');
      final campaigns = ((data['campaigns'] as List?) ?? const [])
          .whereType<Map>()
          .where(_isCreditCampaign)
          .toList();
      final today = _today();
      var grantedToday = false;
      final claimable = <Map>[];
      for (final item in campaigns) {
        if (item['claimStatus'] == 'CLAIMABLE') {
          claimable.add(item);
        } else if (item['claimStatus'] == 'CLAIMED') {
          final id = item['campaignId']?.toString() ?? '';
          if (id.isEmpty) continue;
          final reward = await _json(
            row,
            auth,
            '/sash/api/v1/me/campaigns/$id/reward',
          );
          if (_localDate(reward['claimedAt']) == today) grantedToday = true;
        }
      }

      if (grantedToday) {
        result = {
          'action': 'already',
          'ok': true,
          'message': '今日已签到',
        };
      } else if (claimable.isEmpty) {
        result = {
          'action': 'skip',
          'ok': true,
          'message': '没有可领取的 Credits 活动',
        };
      } else {
        var credits = 0.0;
        var claimed = 0;
        var replayed = 0;
        final failures = <String>[];
        for (final item in claimable) {
          final id = item['campaignId']?.toString() ?? '';
          final key = item['campaignKey']?.toString() ?? id;
          if (id.isEmpty) continue;
          final claim = await _json(
            row,
            auth,
            '/sash/api/v1/me/campaigns/$id/claim',
            method: 'POST',
          );
          final body = claim['data'] is Map
              ? (claim['data'] as Map).cast<String, dynamic>()
              : claim;
          if (body['status'] != 'CLAIMED') {
            failures.add('$key 领取失败');
            continue;
          }
          claimed++;
          final benefit = (body['benefit'] as Map?)?.cast<String, dynamic>() ??
              (item['benefit'] as Map?)?.cast<String, dynamic>() ??
              const {};
          credits += _num(benefit['amount']);
          if (body['replayed'] == true) replayed++;
        }
        if (claimed == 0) {
          result = {
            'action': 'error',
            'ok': false,
            'message': failures.isEmpty ? '领取失败' : failures.join('；'),
          };
        } else {
          final extra = replayed > 0 ? '（$replayed 个重复领取）' : '';
          result = {
            'action': 'claim',
            'ok': true,
            'message': '签到成功$extra',
            'credits': credits,
          };
        }
      }
    } catch (error) {
      result = {
        'action': 'error',
        'ok': false,
        'message': error is ApiException ? error.message : '$error',
      };
    }

    // 领取后刷新一次额度，保持卡片余额是最新的。
    try {
      final latest = await status(row);
      result['status'] = latest;
      await _db.updateStatus(row['id'] as int, latest);
    } catch (_) {
      // 忽略。
    }
    await _db.updateCheckin(
      row['id'] as int,
      ok: result['ok'] == true,
      message: result['message'].toString(),
    );
    await _db.addLog(
      row['id'] as int,
      PlatformKind.qoder,
      action: result['action'].toString(),
      ok: result['ok'] == true,
      message: result['message'].toString(),
      payload: result,
    );
    return result;
  }

  // ---------------------------------------------------------------------------
  // 用量
  // ---------------------------------------------------------------------------

  Future<UsageQueryResult> queryUsage(
    Map<String, Object?> row, {
    int days = 7,
  }) async {
    // 网页端（浏览器登录态）能拿到逐笔明细：模型、会话、是否计费。
    // 拿不到或不属于该账号时回落到客户端热力图（只有按天汇总）。
    final detailed = await _web.queryForAccount(row, days: days);
    if (detailed != null) return detailed;

    final auth = await _load(row);
    var orgId = '';
    try {
      final plan = await _json(row, auth, '/api/v2/user/plan');
      final org = (plan['organization'] as Map?)?.cast<String, dynamic>() ?? const {};
      orgId = (org['org_id'] ?? org['organization_id'] ?? org['id'] ?? '').toString();
    } catch (_) {
      // 没有组织也能查个人用量。
    }
    final heat = await _json(
      row,
      auth,
      '/sash/api/v1/ai-conversations/credits-heatmap'
      '?organization_id=$orgId&days=$days&product=app',
    );
    final items = (heat['items'] as List?) ?? const [];
    final name = (row['display_name']?.toString().isNotEmpty ?? false)
        ? row['display_name'].toString()
        : (row['external_id']?.toString() ?? '');
    final entries = <UsageEntry>[];
    for (final item in items) {
      if (item is! Map) continue;
      final value = _num(item['value']);
      if (value <= 0) continue;
      final date = DateTime.tryParse(item['date']?.toString() ?? '');
      if (date == null) continue;
      entries.add(
        UsageEntry(
          provider: PlatformKind.qoder,
          accountId: row['id'] as int? ?? 0,
          accountName: name,
          time: date,
          title: 'Qoder 当日消耗',
          model: 'Qoder',
          credits: value,
          client: 'Qoder',
        ),
      );
    }
    entries.sort((a, b) => b.time.compareTo(a.time));
    final total = _num(heat['total']).toInt();
    return UsageQueryResult(
      entries: entries,
      total: total == 0 ? entries.length : total,
    );
  }


  /// 桌面端：把 qoder-checkin 脚本的账号库一次性导入（只补缺失账号，不覆盖已有登录态）。
  Future<int> importLegacyAccounts() async {
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) return 0;
    final candidates = [
      p.join(AppPaths.home, 'qoder-checkin', 'qoder_checkin.db'),
      p.join(AppPaths.home, '.qoder-checkin', 'qoder_checkin.db'),
    ];
    String path = '';
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        path = candidate;
        break;
      }
    }
    if (path.isEmpty) return 0;

    sqfliteFfiInit();
    Database? legacy;
    try {
      legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final rows = await legacy.query('accounts');
      final known = {
        for (final row in await _db.listAccountRows())
          '${row['provider']}:${row['external_id']}',
      };
      var imported = 0;
      for (final row in rows) {
        final uid = (row['user_id'] ?? '').toString();
        if (uid.isEmpty || known.contains('qoder:$uid')) continue;
        Object? user;
        try {
          user = jsonDecode((row['user_json'] as String?) ?? '{}');
        } catch (_) {
          user = const <String, dynamic>{};
        }
        final credential = <String, dynamic>{
          'schemaVersion': 1,
          'token': row['token'],
          'refreshToken': row['refresh_token'],
          'expiresAt': (row['expires_at'] as num?)?.toInt() ?? 0,
          'refreshTokenExpiresAt':
              (row['refresh_token_expires_at'] as num?)?.toInt() ?? 0,
          'machineId': row['machine_id'],
          'user': user is Map ? user : const <String, dynamic>{},
          'savedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
        final id = await _db.upsertAccount(
          provider: PlatformKind.qoder,
          externalId: uid,
          displayName: (row['username'] ?? '').toString(),
          endpoint: openapi,
          credential: jsonEncode(credential),
        );
        await _db.addLog(
          id,
          PlatformKind.qoder,
          action: 'import',
          ok: true,
          message: '从 qoder-checkin 账号库导入',
        );
        imported++;
      }
      return imported;
    } catch (_) {
      return 0;
    } finally {
      try {
        await legacy?.close();
      } catch (_) {
        // 忽略。
      }
    }
  }


  // ---------------------------------------------------------------------------
  // 桌面端登录态切换（Linux）
  // ---------------------------------------------------------------------------

  bool get desktopSupported => QoderDesktopAuth.supported;

  static String _isoUtc(Object? seconds) {
    final value = (seconds as num?)?.toInt() ?? 0;
    final time = DateTime.fromMillisecondsSinceEpoch(
      value * 1000,
      isUtc: true,
    );
    return time.toIso8601String().replaceFirst('.000Z', 'Z');
  }

  /// 生成 auth.v1.dat 的内容：沿用当前文件里的 profileOverlay 等附加字段。
  Future<Map<String, dynamic>> desktopPayload(Map<String, Object?> row) async {
    final auth = await _load(row);
    // 写盘前先验证 token 可用（避免把过期登录态推给客户端）。
    var check = await HttpJson.send(
      '$openapi/sash/api/v2/me/usage',
      method: 'GET',
      headers: _headers(
        token: auth['token']?.toString(),
        machineId: auth['machineId']?.toString(),
      ),
    );
    if (check.status == 401) {
      await _refresh(row, auth);
      check = await HttpJson.send(
        '$openapi/sash/api/v2/me/usage',
        method: 'GET',
        headers: _headers(
          token: auth['token']?.toString(),
          machineId: auth['machineId']?.toString(),
        ),
      );
    }
    if (check.status != 200) {
      throw ApiException('目标账号登录态不可用: HTTP ${check.status}');
    }

    final user = (auth['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    final current = await QoderDesktopAuth.read();
    return {
      'schemaVersion': 1,
      'token': auth['token'],
      'refreshToken': auth['refreshToken'],
      'expiresAt': _isoUtc(auth['expiresAt']),
      'refreshTokenExpiresAt': _isoUtc(auth['refreshTokenExpiresAt']),
      'user': {
        'id': (user['id'] ?? '').toString(),
        'name': (user['name'] ?? user['username'] ?? '').toString(),
        'email': (user['email'] ?? '').toString(),
        'phone': (user['phone'] ?? '').toString(),
        'avatarUrl': (user['avatarUrl'] ?? user['avatar'] ?? '').toString(),
      },
      if (current != null && current['profileOverlay'] != null)
        'profileOverlay': current['profileOverlay'],
      if (current != null && current['firstLoginOnboardingSeen'] != null)
        'firstLoginOnboardingSeen': current['firstLoginOnboardingSeen'],
    };
  }

  /// 切换到 [row] 对应账号：返回备份路径。
  Future<String> switchDesktop(Map<String, Object?> row) async {
    final payload = await desktopPayload(row);
    return QoderDesktopAuth.write(payload);
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  static double _num(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static bool _isCreditCampaign(Map item) {
    final action = item['actionType']?.toString().toUpperCase().replaceAll('_', '') ?? '';
    final benefit = (item['benefit'] as Map?) ?? const {};
    return action == 'CLAIMBENEFIT' || benefit['kind'] == 'CREDITS';
  }

  static String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  static String _localDate(Object? value) {
    if (value is! String || value.isEmpty) return '';
    final parsed = DateTime.tryParse(value.replaceFirst('Z', '+00:00'));
    if (parsed == null) return '';
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  static String _userIdOf(Map<String, dynamic> auth) {
    final user = (auth['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    return (user['id'] ?? user['user_id'] ?? user['uid'] ?? '').toString();
  }

  static String _userNameOf(Map<String, dynamic> auth) {
    final user = (auth['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    return (user['name'] ?? user['username'] ?? user['user_name'] ?? '').toString();
  }

  static String _randomString(int length) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(length, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
  }

  static String _codeChallenge(String verifier) {
    final digest = SHA256Digest().process(utf8.encode(verifier));
    return base64Url.encode(digest).replaceAll('=', '');
  }

  static String _uuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
