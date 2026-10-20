import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import '../../data/app_database.dart';
import '../../models/account.dart';
import '../../models/login_session.dart';
import '../../util/app_paths.dart';
import '../desktop/desktop_client.dart';
import '../http_json.dart';
import 'trae_crypto.dart';

/// Trae 平台服务：登录态加解密、刷新、状态查询与签到。
///
/// 线协议逐项对齐 Python 版 `trae_tool.py`：PKCE 授权 + `ExchangeToken`，
/// `checkin_credits/status` 与 `checkin_credits/claim`，以及
/// `pay/ide_user_ent_usage` 真实余额。
class TraeService {
  TraeService(this._db);

  final AppDatabase _db;

  static const String clientId = 'ono9krqynydwx5';
  static const String apiHost = 'https://api.trae.cn';
  static const String loginHost = 'https://www.trae.cn';
  static const String desktopAuthKey = 'iCubeAuthInfo://icube.cloudide';
  static const String _defaultVersion = '3.3.99';
  static const String _appId = '6eefa01c-1036-4c7e-9ca5-d891f63bfcd8';

  Map<String, dynamic>? _identityCache;
  String? _versionCache;

  static String get _home => AppPaths.home;

  // ---------------------------------------------------------------------------
  // 设备指纹
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _identity() async {
    if (_identityCache != null) return _identityCache!;
    final file = await AppPaths.traeIdentityFile();
    for (final candidate in [file, File('$_home/.trae-checkin/identity.json')]) {
      try {
        if (await candidate.exists()) {
          final decoded = jsonDecode(await candidate.readAsString());
          if (decoded is Map && decoded['machineId'] != null && decoded['deviceId'] != null) {
            return _identityCache = decoded.cast<String, dynamic>();
          }
        }
      } catch (_) {
        // 忽略损坏的旧文件，继续使用默认身份。
      }
    }
    final rng = Random.secure();
    final identity = <String, dynamic>{
      'machineId': _randomHex(rng, 32),
      'deviceId': _randomHex(rng, 16),
      'deviceName': _defaultDeviceName(),
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(identity));
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}
    }
    return _identityCache = identity;
  }

  static String _randomHex(Random rng, int bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _defaultDeviceName() {
    switch (Platform.operatingSystem) {
      case 'macos':
        return 'Mac-PC';
      case 'windows':
        return 'Windows-PC';
      case 'android':
        return 'Android';
      case 'ios':
        return 'iPhone';
      default:
        return 'Linux-PC';
    }
  }

  static String _platformSystem() {
    switch (Platform.operatingSystem) {
      case 'linux':
        return 'Linux';
      case 'macos':
        return 'Darwin';
      case 'windows':
        return 'Windows';
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      default:
        return Platform.operatingSystem;
    }
  }

  static String _cpuArch() {
    try {
      final abi = Abi.current();
      if (abi == Abi.linuxX64 || abi == Abi.macosX64 || abi == Abi.windowsX64) return 'x86_64';
      if (abi == Abi.linuxArm64 || abi == Abi.macosArm64) return 'aarch64';
      if (abi == Abi.androidArm64) return 'aarch64';
      return abi.toString();
    } catch (_) {
      return 'x86_64';
    }
  }

  Future<String> _clientVersion() async {
    if (_versionCache != null) return _versionCache!;
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final programFiles = Platform.environment['PROGRAMFILES'] ?? '';
    final programFilesX86 = Platform.environment['PROGRAMFILES(X86)'] ?? '';
    final candidates = [
      '/usr/share/trae-cn/resources/app/package.json',
      '/usr/share/trae/resources/app/package.json',
      '$_home/Library/Application Support/Trae CN/User/globalStorage/storage.json',
      // Windows：覆盖常见的三处安装位置（用户级安装 + 两个 Program Files）。
      '$localAppData/Programs/Trae CN/resources/app/package.json',
      '$programFiles/Trae CN/resources/app/package.json',
      '$programFilesX86/Trae CN/resources/app/package.json',
    ];
    for (final path in candidates) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['version'] != null) {
          return _versionCache = decoded['version'].toString();
        }
      } catch (_) {
        continue;
      }
    }
    return _versionCache = _defaultVersion;
  }

  Future<Map<String, dynamic>> _deviceInfo() async {
    final identity = await _identity();
    final version = await _clientVersion();
    final osInfo = _platformSystem();
    return {
      'DeviceID': identity['deviceId'],
      'MachineID': identity['machineId'],
      'PlatformCode': 'IDE_PC',
      'DeviceType': 'PC',
      'DeviceName': identity['deviceName'] ?? _defaultDeviceName(),
      'DeviceModel': osInfo,
      'ClientVersion': version,
      'DevicePublicKey': RsaPem.generatePublicKeyPem(),
      'DeviceBrand': 'Generic',
      'DeviceCPU': _cpuArch(),
      'OSInfo': osInfo,
      'OSVersion': '$osInfo ${Platform.operatingSystemVersion}',
    };
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  static String _nowIso() => DateTime.now().toUtc().toIso8601String().replaceAll('+00:00', 'Z');

  static Object? _pick(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      if (data[key] != null) return data[key];
    }
    return null;
  }

  static Map<String, dynamic> _resultOf(Map<String, dynamic> payload) {
    final result = payload['Result'] ?? payload['result'];
    return result is Map ? result.cast<String, dynamic>() : <String, dynamic>{};
  }

  @override
  String toString() => 'TraeService';

  // ---------------------------------------------------------------------------
  // 登录
  // ---------------------------------------------------------------------------

  Future<LoginSession> startLogin({
    String label = '',
    Duration timeout = const Duration(minutes: 5),
    void Function()? onUpdate,
  }) async {
    final verifier = TraeCrypto.randomUrlSafe(48);
    final challenge = TraeCrypto.codeChallenge(verifier);
    final identity = await _identity();
    final version = await _clientVersion();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final callback = Completer<Uri>();

    final session = LoginSession(
      id: 'trae-${DateTime.now().microsecondsSinceEpoch}',
      provider: PlatformKind.trae,
      authUrl: '',
      label: label,
      expiresAt: DateTime.now().add(timeout),
    );

    server.listen((request) async {
      if (request.uri.path != '/authorize') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        "<!doctype html><meta charset='utf-8'><title>Trae 登录成功</title>"
        "<body style='font-family:system-ui;text-align:center;padding:60px'>"
        "<h2>登录成功</h2><p>可以关闭本页面，回到签到中枢。</p></body>",
      );
      await request.response.close();
      if (!callback.isCompleted) callback.complete(request.uri);
    });

    final query = <String, String>{
      'login_version': '1',
      'auth_from': 'trae',
      'login_channel': 'native_ide',
      'plugin_version': version,
      'auth_type': 'local',
      'client_id': clientId,
      'redirect': '0',
      'login_trace_id': _uuid(),
      'auth_callback_url': 'http://127.0.0.1:$port/authorize',
      'machine_id': identity['machineId'].toString(),
      'device_id': identity['deviceId'].toString(),
      'x_device_id': identity['deviceId'].toString(),
      'x_machine_id': identity['machineId'].toString(),
      'x_device_brand': 'Generic',
      'x_device_type': Platform.operatingSystem,
      'x_os_version': '${_platformSystem()} ${Platform.operatingSystemVersion}',
      'x_env': '',
      'x_app_version': version,
      'x_app_type': 'stable',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    };
    session.authUrl = '$loginHost/authorization?${_encodeQuery(query)}';

    unawaited(_awaitCallback(session, server, callback, verifier, timeout, onUpdate));
    return session;
  }

  Future<void> _awaitCallback(
    LoginSession session,
    HttpServer server,
    Completer<Uri> callback,
    String verifier,
    Duration timeout,
    void Function()? onUpdate,
  ) async {
    try {
      final uri = await callback.future.timeout(timeout, onTimeout: () => throw ApiException('等待登录超时'));
      await server.close(force: true);
      session.status = LoginStatus.exchanging;
      session.message = '正在换取登录令牌';
      onUpdate?.call();

      final params = uri.queryParameters;
      final error = params['error_code'] ?? params['error'];
      if (error != null && error.isNotEmpty) {
        throw ApiException('授权被拒绝: $error ${params['error_msg'] ?? ''}');
      }
      final code = _extractAuthCode(params);
      if (code == null) throw ApiException('回跳未携带授权码');

      final result = await _exchangeAuthCode(code, verifier);
      final token = _pick(result, ['Token', 'token'])?.toString() ?? '';
      final info = await _getUserInfo(token);
      final auth = _buildAuthPayload(result, info);
      final displayName =
          (auth['account'] as Map?)?['username']?.toString() ?? auth['userId'].toString();
      final credential = TraeCrypto.encrypt(auth);
      final id = await _db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: auth['userId'].toString(),
        displayName: displayName,
        endpoint: (auth['host'] ?? apiHost).toString(),
        credential: credential,
        label: session.label,
      );
      await _db.addLog(id, PlatformKind.trae, action: 'login', ok: true, message: 'Web 登录成功', payload: {'display_name': displayName});
      session
        ..status = LoginStatus.success
        ..message = '登录成功'
        ..accountId = id
        ..accountName = displayName;
    } catch (error) {
      try {
        await server.close(force: true);
      } catch (_) {
        // 回调服务可能已随成功路径关闭。
      }
      session
        ..status = LoginStatus.failed
        ..message = error is ApiException ? error.message : error.toString();
    } finally {
      onUpdate?.call();
    }
  }

  static String? _extractAuthCode(Map<String, String> params) {
    for (final key in ['authCodeInfo', 'code', 'authCode', 'AuthCode']) {
      final value = params[key];
      if (value == null || value.isEmpty) continue;
      try {
        final parsed = jsonDecode(value);
        if (parsed is Map) {
          final code = parsed['AuthCode'] ?? parsed['code'];
          if (code != null && code.toString().isNotEmpty) return code.toString();
        }
      } catch (_) {
        // 不是 JSON，按原始字符串处理。
      }
      return value;
    }
    return null;
  }

  Future<Map<String, dynamic>> _exchangeAuthCode(String authCode, String codeVerifier) async {
    final result = await HttpJson.send(
      '$apiHost/trae/api/v3/oauth/ExchangeToken',
      headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
      body: {
        'ClientID': clientId,
        'AuthCode': authCode,
        'CodeVerifier': codeVerifier,
        'DeviceInfo': await _deviceInfo(),
        'IDEVersion': await _clientVersion(),
      },
    );
    final data = _resultOf(result.body);
    if (!result.ok || _pick(data, ['Token', 'token']) == null) {
      final message = result.body['message'] ?? result.body['Message'] ?? 'HTTP ${result.status}';
      throw ApiException('ExchangeToken 失败: $message');
    }
    return data;
  }

  Future<Map<String, dynamic>> _getUserInfo(String token) async {
    final version = await _clientVersion();
    final result = await HttpJson.send(
      '$apiHost/cloudide/api/v3/trae/GetUserInfo',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Cloud-IDE-JWT $token',
        'X-Cloudide-Token': token,
      },
      body: {'ReqSource': 'IDE', 'IDEVersion': version},
    );
    if (!result.ok) throw ApiException('GetUserInfo 失败: HTTP ${result.status}');
    final payload = result.body;
    final data = payload['Result'] ?? payload['Data'] ?? payload;
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  static String _normalizeExpire(Object? raw, Object? duration) {
    final now = DateTime.now();
    if (raw != null) {
      final number = double.tryParse(raw.toString());
      if (number != null) {
        final nowMs = now.millisecondsSinceEpoch.toDouble();
        if (number > nowMs || number > 1e12) {
          return DateTime.fromMillisecondsSinceEpoch(number.toInt(), isUtc: true)
              .toIso8601String()
              .replaceAll('+00:00', 'Z');
        }
      }
    }
    if (duration != null) {
      final seconds = double.tryParse(duration.toString());
      if (seconds != null) {
        return now.add(Duration(milliseconds: (seconds * 1000).round())).toUtc().toIso8601String().replaceAll('+00:00', 'Z');
      }
    }
    if (raw != null) {
      final parsed = DateTime.tryParse(raw.toString());
      if (parsed != null) return parsed.toUtc().toIso8601String().replaceAll('+00:00', 'Z');
    }
    return now.add(const Duration(hours: 2)).toUtc().toIso8601String().replaceAll('+00:00', 'Z');
  }

  Map<String, dynamic> _buildAuthPayload(Map<String, dynamic> result, Map<String, dynamic> info) {
    final token = _pick(result, ['Token', 'token'])?.toString();
    final refreshToken = _pick(result, ['RefreshToken', 'refreshToken'])?.toString();
    if (token == null || token.isEmpty) throw ApiException('ExchangeToken 未返回 Token');

    final expiredAt = _normalizeExpire(
      _pick(result, ['TokenExpireAt', 'tokenExpireAt']),
      _pick(result, ['TokenExpireDuration', 'tokenExpireDuration']),
    );
    final refreshRaw = _pick(result, ['RefreshExpireAt', 'refreshExpireAt']);
    final refreshExpired = refreshRaw != null
        ? _normalizeExpire(refreshRaw, null)
        : _normalizeExpire(DateTime.now().millisecondsSinceEpoch + 365 * 86400000, null);

    final userInfo = (info['UserInfo'] is Map ? info['UserInfo'] as Map : info).cast<String, dynamic>();
    final userId = (_pick(userInfo, ['UserID', 'userId', 'user_id']) ?? info['UserID'])?.toString() ?? '';
    if (userId.isEmpty) throw ApiException('GetUserInfo 未返回 UserID');
    final aiRegion = (_pick(userInfo, ['AIRegion', 'aiRegion']) ?? info['AIRegion'] ?? 'CN').toString();

    String str(Object? value) => value?.toString() ?? '';
    // 客户端用 `account.scope` 判断是否已登录（为空直接当未登录），
    // 但 GetUserInfo 对部分账号不返回 Scope / LoginScope / StoreRegion，
    // 这里补齐成客户端自己写登录态时的默认值，避免存下的登录态客户端不认。
    String strOr(Object? value, String fallback) {
      final text = str(value);
      return text.isEmpty ? fallback : text;
    }

    return {
      'token': token,
      'refreshToken': refreshToken,
      'expiredAt': expiredAt,
      'refreshExpiredAt': refreshExpired,
      'tokenReleaseAt': _nowIso(),
      'userId': userId,
      'host': apiHost,
      'userRegion': {'region': aiRegion, '_aiRegion': aiRegion},
      'account': {
        'username': str(_pick(userInfo, ['ScreenName', 'username'])),
        'iss': '',
        'iat': 0,
        'organization': str(_pick(userInfo, ['Organization', 'organization'])),
        'work_country': str(_pick(userInfo, ['WorkCountry', 'work_country'])),
        'email': str(_pick(userInfo, ['NonPlainTextEmail', 'email'])),
        'avatar_url': str(_pick(userInfo, ['AvatarUrl', 'avatar_url'])),
        'description': str(_pick(userInfo, ['Description', 'description'])),
        'scope': strOr(_pick(userInfo, ['Scope', 'scope']), 'marscode'),
        'loginScope': strOr(_pick(userInfo, ['LoginScope', 'loginScope']), 'trae'),
        'nonPlainTextMobile': str(userInfo['NonPlainTextMobile']),
        'storeCountryCode': str(userInfo['StoreCountryCode']),
        'storeCountrySrc': str(userInfo['StoreCountrySrc']),
        'storeRegion': strOr(_pick(info, ['StoreRegion', 'storeRegion']), aiRegion),
        'userTag': strOr(_pick(info, ['UserTag', 'userTag']), 'cn'),
        'migrateToSG': userInfo['MigrateToSG'] == true,
      },
    };
  }

  // ---------------------------------------------------------------------------
  // 登录态刷新
  // ---------------------------------------------------------------------------

  Future<bool> _refresh(Map<String, dynamic> auth) async {
    final refreshToken = auth['refreshToken'];
    if (refreshToken == null || refreshToken.toString().isEmpty) return false;
    final host = auth['host']?.toString() ?? apiHost;
    final result = await HttpJson.send(
      '$host/cloudide/api/v3/trae/oauth/ExchangeToken',
      headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
      body: {
        'ClientID': clientId,
        'RefreshToken': refreshToken,
        'ClientSecret': '-',
        'UserID': auth['userId']?.toString() ?? '',
      },
    );
    final data = _resultOf(result.body);
    final token = _pick(data, ['Token', 'token'])?.toString();
    if (!result.ok || token == null || token.isEmpty) return false;
    auth['token'] = token;
    final newRefresh = _pick(data, ['RefreshToken', 'refreshToken'])?.toString();
    if (newRefresh != null && newRefresh.isNotEmpty) auth['refreshToken'] = newRefresh;
    if (_pick(data, ['TokenExpireAt', 'tokenExpireAt']) != null ||
        _pick(data, ['TokenExpireDuration', 'tokenExpireDuration']) != null) {
      auth['expiredAt'] = _normalizeExpire(
        _pick(data, ['TokenExpireAt', 'tokenExpireAt']),
        _pick(data, ['TokenExpireDuration', 'tokenExpireDuration']),
      );
    }
    return true;
  }

  Future<Map<String, dynamic>> _ensureFresh(Map<String, dynamic> auth) async {
    var expiredAt = 0;
    final raw = auth['expiredAt'];
    if (raw != null) {
      final parsed = DateTime.tryParse(raw.toString());
      if (parsed != null) expiredAt = parsed.millisecondsSinceEpoch;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (expiredAt == 0 || expiredAt - nowMs < 30 * 60 * 1000) {
      await _refresh(auth);
    }
    return auth;
  }

  Future<Map<String, dynamic>> _loadAuth(Map<String, Object?> row) async {
    final auth = TraeCrypto.decrypt(row['credential'] as String);
    auth['host'] = (auth['host'] == null || auth['host'].toString().isEmpty)
        ? (row['endpoint']?.toString() ?? apiHost)
        : auth['host'];
    return _ensureFresh(auth);
  }

  Future<void> _saveAuth(Map<String, Object?> row, Map<String, dynamic> auth) async {
    final username = (auth['account'] as Map?)?['username']?.toString();
    await _db.updateCredential(
      row['id'] as int,
      credential: TraeCrypto.encrypt(auth),
      displayName: (username != null && username.isNotEmpty) ? username : null,
    );
  }

  // ---------------------------------------------------------------------------
  // 请求头与业务接口
  // ---------------------------------------------------------------------------

  static String _deviceId() =>
      '${DateTime.now().millisecondsSinceEpoch}${10 + Random().nextInt(90)}';

  Future<Map<String, String>> _headers(Map<String, dynamic> auth) async {
    final identity = await _identity();
    final version = await _clientVersion();
    final system = Platform.operatingSystem;
    final deviceType = const {
      'linux': 'linux',
      'macos': 'mac',
      'windows': 'windows',
      'android': 'linux',
      'ios': 'mac',
    }[system] ??
        'unknown';
    return {
      'Authorization': 'Cloud-IDE-JWT ${auth['token']}',
      'X-Cloudide-Token': auth['token'].toString(),
      'x-uid': auth['userId']?.toString() ?? '',
      'x-app-id': _appId,
      'x-device-id': _deviceId(),
      'x-machine-id': identity['machineId'].toString(),
      'x-request-id': _uuid(),
      'x-ide-version': version,
      'x-ide-version-code': version.replaceAll('.', ''),
      'x-device-type': deviceType,
      'x-os-version': '${_platformSystem()} ${Platform.operatingSystemVersion}',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  Future<JsonResult> _post(
    Map<String, dynamic> auth,
    String path,
    Map<String, dynamic> body, {
    Map<String, String> overrides = const {},
  }) async {
    final host = auth['host']?.toString() ?? apiHost;
    final url = '$host$path';
    var headers = {...await _headers(auth), ...overrides};
    var result = await HttpJson.send(url, headers: headers, body: body);
    if (result.status == 401 && await _refresh(auth)) {
      headers = {...await _headers(auth), ...overrides};
      result = await HttpJson.send(url, headers: headers, body: body);
    }
    return result;
  }

  Future<Map<String, dynamic>> _usageRequest(Map<String, dynamic> auth) async {
    final result = await _post(auth, '/trae/api/v2/pay/ide_user_ent_usage', {
      'require_usage': true,
      'req_source': 1,
    });
    final code = result.body['code'];
    if (result.status != 200 || (code != null && code != 0)) {
      final message = result.body['message'] ?? result.body['Message'] ?? 'HTTP ${result.status}';
      throw ApiException('查询真实余额失败: $message');
    }
    final packs = (result.body['user_entitlement_pack_list'] as List?) ?? const [];
    var total = 0.0;
    var used = 0.0;
    var unlimited = false;
    final packages = <Map<String, dynamic>>[];
    for (final raw in packs) {
      if (raw is! Map) continue;
      final baseInfo = raw['entitlement_base_info'];
      final quota = (baseInfo is Map ? baseInfo['quota'] : null) as Map? ?? const {};
      final usage = raw['usage'] as Map? ?? const {};
      final limitRaw = quota['credits_limit'];
      var amount = double.tryParse('${usage['credits_amount'] ?? 0}') ?? 0.0;
      amount = amount < 0 ? 0 : amount;
      num? limit = limitRaw is num ? limitRaw : null;
      if (limitRaw == -1) {
        unlimited = true;
      } else if (limit != null && limit > 0) {
        total += limit.toDouble();
      }
      if (limit != 0) used += amount;
      packages.add({'limit': limit, 'used': amount});
    }
    num clean(double value) => value == value.roundToDouble() ? value.round() : double.parse(value.toStringAsFixed(6));
    final left = total - used < 0 ? 0.0 : total - used;
    return {
      'source': 'ide_user_ent_usage',
      'isCreditsBilling': result.body['is_credits_billing'] == true,
      'creditsTotal': unlimited ? -1 : clean(total),
      'creditsLeft': unlimited ? -1 : clean(left),
      'creditsUsed': clean(used),
      'unlimited': unlimited,
      'packCount': packages.length,
      'packages': packages,
    };
  }

  /// 查询签到状态并附带真实余额。顺带返回本次使用（可能已续期）的登录态。
  Future<(Map<String, dynamic> status, Map<String, dynamic> auth)> _fetchStatus(
    Map<String, Object?> row,
  ) async {
    final auth = await _loadAuth(row);
    final checkin = await _post(auth, '/trae/api/v2/ug/checkin_credits/status', const {});
    if (checkin.status != 200 || checkin.body['code'] != 0) {
      final message = checkin.body['message'] ?? 'HTTP ${checkin.status}';
      throw ApiException('查询签到状态失败: $message');
    }
    final usage = await _usageRequest(auth);
    return (
      {
        ...checkin.body,
        'usage': usage,
        'credits_left': usage['creditsLeft'],
        'credits_total': usage['creditsTotal'],
      },
      auth,
    );
  }

  Future<Map<String, dynamic>> status(Map<String, Object?> row) async {
    final (result, auth) = await _fetchStatus(row);
    await _saveAuth(row, auth);
    await _db.updateStatus(row['id'] as int, result);
    return result;
  }

  Future<Map<String, dynamic>> checkin(Map<String, Object?> row) async {
    final (initialStatus, auth) = await _fetchStatus(row);
    var statusPayload = initialStatus;
    Map<String, dynamic> result;
    if (statusPayload['checked_in'] == true) {
      result = {'action': 'already', 'ok': true, 'message': '今日已签到', 'status': statusPayload};
    } else {
      final claim = await _post(auth, '/trae/api/v2/ug/checkin_credits/claim', const {});
      if (claim.status != 200 || claim.body['code'] != 0) {
        final message = claim.body['message'] ?? 'HTTP ${claim.status}';
        result = {
          'action': 'claim',
          'ok': false,
          'message': '签到失败: $message',
          'claim': claim.body,
          'status': statusPayload,
        };
      } else {
        final gained = _pick(claim.body, ['gained_credits', 'credits_gained', 'reward', 'credits']);
        result = {
          'action': 'claim',
          'ok': true,
          'message': '签到成功',
          'credits': gained,
          'claim': claim.body,
          'status': statusPayload,
        };
      }
      statusPayload = (await _fetchStatus(row)).$1;
      result['status'] = statusPayload;
    }
    await _saveAuth(row, auth);
    await _db.updateStatus(row['id'] as int, statusPayload);
    await _db.updateCheckin(row['id'] as int, ok: result['ok'] == true, message: result['message'].toString());
    await _db.addLog(
      row['id'] as int,
      PlatformKind.trae,
      action: result['action'].toString(),
      ok: result['ok'] == true,
      message: result['message'].toString(),
      payload: result,
    );
    return result;
  }

  // ---------------------------------------------------------------------------
  // 从本机 Trae 客户端导入登录态
  // ---------------------------------------------------------------------------

  Future<List<int>> importFromDesktop() async {
    // 三个桌面平台的登录态位置：Linux `~/.config`、macOS `~/Library/Application Support`、
    // Windows 的 `%APPDATA%` / `%LOCALAPPDATA%`（最后一组由 DesktopClient 探测）。
    const names = ['Trae CN', 'TRAE SOLO CN', 'Trae', 'TRAE SOLO'];
    final paths = <String>[];
    for (final name in names) {
      for (final base in ['$_home/.config', '$_home/Library/Application Support']) {
        paths.add('$base/$name/User/globalStorage/storage.json');
      }
    }
    paths.addAll(DesktopClient.traeAuthFiles());

    final imported = <int>[];
    final seen = <String>{};
    for (final path in paths) {
      if (!seen.add(path)) continue;
      final file = File(path);
      try {
        if (!await file.exists()) continue;
        final storage = jsonDecode(await file.readAsString());
        if (storage is! Map) continue;
        final raw = storage[desktopAuthKey];
        if (raw == null) continue;
        final Map<String, dynamic> auth;
        final text = raw.toString();
        if (text.trimLeft().startsWith('{')) {
          auth = (jsonDecode(text) as Map).cast<String, dynamic>();
        } else {
          auth = TraeCrypto.decrypt(text);
        }
        final displayName = (auth['account'] as Map?)?['username']?.toString() ?? auth['userId'].toString();
        imported.add(await _db.upsertAccount(
          provider: PlatformKind.trae,
          externalId: auth['userId'].toString(),
          displayName: displayName,
          endpoint: (auth['host'] ?? apiHost).toString(),
          credential: TraeCrypto.encrypt(auth),
        ));
      } catch (_) {
        continue;
      }
    }
    return imported;
  }

  static String _encodeQuery(Map<String, String> params) =>
      params.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

  static String _uuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
