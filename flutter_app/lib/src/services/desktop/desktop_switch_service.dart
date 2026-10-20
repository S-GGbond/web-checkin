import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../models/account.dart';
import '../trae/trae_crypto.dart';
import 'desktop_client.dart';
import 'wb_envelope.dart';

/// 一次「切换到客户端」的结果。
class DesktopSwitchResult {
  const DesktopSwitchResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// 某平台客户端的探测结果，供设置页展示。
class DesktopClientInfo {
  const DesktopClientInfo({
    required this.provider,
    required this.authFiles,
    required this.executable,
    required this.activeExternalId,
  });

  final PlatformKind provider;
  final List<String> authFiles;
  final String? executable;
  final String? activeExternalId;

  /// Trae 只需要登录态文件；WorkBuddy 还必须能从主程序取到本机密钥。
  bool get canSwitch => authFiles.isNotEmpty && (provider == PlatformKind.trae || executable != null);

  String? get authFile => authFiles.isEmpty ? null : authFiles.first;

  /// 主程序文件名，用于设置页展示。
  String get executableName => executable == null ? '未找到' : p.basename(executable!);

  String get summary {
    if (authFiles.isEmpty) return '未检测到客户端登录态';
    if (provider == PlatformKind.workbuddy && executable == null) return '已找到登录态，但未找到客户端主程序';
    return '已就绪';
  }
}

/// 从客户端读出的、可直接入库的账号。
class DesktopAccountDraft {
  const DesktopAccountDraft({
    required this.provider,
    required this.externalId,
    required this.displayName,
    required this.endpoint,
    required this.credential,
  });

  final PlatformKind provider;
  final String externalId;
  final String displayName;
  final String endpoint;
  final String credential;

  String get key => '${provider.id}:$externalId';
}

/// 把账号库里的登录态写回桌面客户端，并重启客户端。
///
/// 写入前置条件统一为「客户端完全退出 → 备份 → 原子写入 → 重启」，
/// 因为客户端运行时会回写登录态，直接覆盖会被它还原。
class DesktopSwitchService {
  Uint8List? _protectorKeyCache;

  static bool get supported => DesktopClient.supported;

  /// 探测客户端状态。
  ///
  /// [refreshExecutable] 只在用户主动「重新探测」时为真：安装目录搜索较慢，
  /// 启动/切换后的例行刷新直接复用缓存，避免界面卡顿。
  Future<DesktopClientInfo> inspect(PlatformKind provider, {bool refreshExecutable = false}) async {
    final files = _authFiles(provider);
    final active = await currentExternalId(provider);
    return DesktopClientInfo(
      provider: provider,
      authFiles: files,
      executable: await DesktopClient.executable(provider, refresh: refreshExecutable),
      activeExternalId: active,
    );
  }

  /// 读取客户端**当前登录**的账号，转成账号库能直接使用的凭据。
  ///
  /// 客户端只保存当前登录的那一个账号（Trae 的 storage.json、WorkBuddy 的
  /// workbuddy-desktop.info 主字段），所以能自动发现的就是「此刻客户端里登着的账号」。
  /// 未登录、未安装或 WorkBuddy 取不到本机密钥时返回 null。
  Future<DesktopAccountDraft?> readCurrentAccount(PlatformKind provider) async {
    if (!supported) return null;
    final files = _authFiles(provider);
    if (files.isEmpty) return null;
    try {
      final decoded = jsonDecode(await File(files.first).readAsString());
      if (decoded is! Map) return null;
      return provider == PlatformKind.trae
          ? _readTraeAccount(decoded)
          : await _readWorkbuddyAccount(decoded);
    } catch (_) {
      return null;
    }
  }

  static DesktopAccountDraft? _readTraeAccount(Map<dynamic, dynamic> storage) {
    final raw = storage[DesktopClient.traeAuthKey];
    if (raw == null) return null;
    final text = raw.toString();
    final auth = text.trimLeft().startsWith('{')
        ? (jsonDecode(text) as Map).cast<String, dynamic>()
        : TraeCrypto.decrypt(text);
    final userId = auth['userId']?.toString();
    if (userId == null || userId.isEmpty) return null;
    normalizeTraeAuth(auth);
    final account = auth['account'] is Map ? (auth['account'] as Map) : const {};
    return DesktopAccountDraft(
      provider: PlatformKind.trae,
      externalId: userId,
      displayName: account['username']?.toString() ?? userId,
      endpoint: auth['host']?.toString() ?? 'https://api.trae.cn',
      credential: TraeCrypto.encrypt(auth),
    );
  }

  Future<DesktopAccountDraft?> _readWorkbuddyAccount(Map<dynamic, dynamic> info) async {
    final account = info['account'];
    if (account is! Map) return null;
    final uid = account['uid']?.toString();
    if (uid == null || uid.isEmpty) return null;

    final executable = await DesktopClient.executable(PlatformKind.workbuddy);
    if (executable == null) return null;
    final key = _protectorKeyCache ??= await _readProtectorKey(executable);

    final liveAuth = info['auth'];
    if (liveAuth is! Map) return null;
    final auth = Map<String, dynamic>.from(liveAuth);
    for (final field in ['accessToken', 'refreshToken']) {
      final value = auth[field];
      if (value == null) continue;
      final plain = WbEnvelope.isWrapped(value) ? WbEnvelope.unwrap(value, key) : value.toString();
      if (plain == null || plain.isEmpty) return null;
      auth[field] = plain;
    }
    if (auth['accessToken'] == null) return null;

    final plainAccount = Map<String, dynamic>.from(account);
    for (final field in ['nickname', 'phoneNumber']) {
      final value = plainAccount[field];
      if (value != null && WbEnvelope.isWrapped(value)) {
        final plain = WbEnvelope.unwrap(value, key);
        if (plain != null) plainAccount[field] = plain;
      }
    }

    final domain = auth['domain']?.toString() ?? 'www.workbuddy.cn';
    return DesktopAccountDraft(
      provider: PlatformKind.workbuddy,
      externalId: uid,
      displayName: plainAccount['nickname']?.toString() ?? uid,
      endpoint: domain.contains('://') ? domain : 'https://$domain',
      credential: jsonEncode({
        'auth': auth,
        'account': plainAccount,
        'snapshot': {
          'accounts': info['accounts'] ?? const [],
          'allAccounts': info['allAccounts'] ?? const [],
        },
      }),
    );
  }

  List<String> _authFiles(PlatformKind provider) =>
      provider == PlatformKind.trae ? DesktopClient.traeAuthFiles() : DesktopClient.workbuddyAuthFiles();

  /// 读取客户端当前登录的账号 id；未登录或客户端未安装时返回 null。
  Future<String?> currentExternalId(PlatformKind provider) async {
    if (!supported) return null;
    try {
      final files = _authFiles(provider);
      if (files.isEmpty) return null;
      final text = await File(files.first).readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      if (provider == PlatformKind.trae) {
        final raw = decoded[DesktopClient.traeAuthKey];
        if (raw == null) return null;
        final value = raw.toString();
        final auth = value.trimLeft().startsWith('{')
            ? jsonDecode(value) as Map
            : TraeCrypto.decrypt(value);
        return auth['userId']?.toString();
      }
      final account = decoded['account'];
      return account is Map ? account['uid']?.toString() : null;
    } catch (_) {
      return null;
    }
  }

  /// 把 [credential]（账号库中的原始凭据）写入客户端并重启。
  Future<DesktopSwitchResult> switchTo({
    required PlatformKind provider,
    required String credential,
    required String displayName,
    bool restart = true,
    void Function(String phase)? onPhase,
  }) async {
    if (!supported) {
      return const DesktopSwitchResult(ok: false, message: '当前平台不支持客户端账号切换');
    }
    String? executable;
    var stopped = false;
    try {
      final files = _authFiles(provider);
      if (files.isEmpty) {
        return DesktopSwitchResult(
          ok: false,
          message: '未检测到 ${provider.label} 客户端登录态，请先启动客户端并完成一次登录',
        );
      }
      executable = await DesktopClient.executable(provider);
      if (provider == PlatformKind.workbuddy && executable == null) {
        return const DesktopSwitchResult(ok: false, message: '未找到 WorkBuddy 主程序，无法加密写入登录态');
      }

      // 先校验账号库里的凭据可用、并把 WorkBuddy 需要的密钥取到手，再动客户端。
      final traeAuth = provider == PlatformKind.trae ? _traeAuth(credential) : null;
      final traePayload = traeAuth == null ? null : TraeCrypto.encrypt(normalizeTraeAuth(traeAuth));
      final workbuddyPayload =
          provider == PlatformKind.workbuddy ? _workbuddyPayload(credential) : null;
      final protectorKey = provider == PlatformKind.workbuddy
          ? (_protectorKeyCache ??= await _readProtectorKey(executable!))
          : null;

      onPhase?.call('正在关闭 ${provider.label} 客户端…');
      final left = await DesktopClient.stop(provider);
      stopped = true;
      if (left.isNotEmpty) {
        return DesktopSwitchResult(
          ok: false,
          message: '${provider.label} 客户端仍在运行（pid ${left.join('、')}），请手动退出后重试',
        );
      }

      onPhase?.call('正在写入登录态…');
      for (final file in files) {
        final original = await File(file).readAsString();
        final decoded = jsonDecode(original);
        if (decoded is! Map) throw const FormatException('客户端登录态不是合法 JSON');
        DesktopClient.backup(file);
        if (provider == PlatformKind.trae) {
          decoded[DesktopClient.traeAuthKey] = traePayload;
          // 客户端按 usertag 里的 userId → 地区映射判断登录态属于哪个区，
          // 缺了这一项时会直接把新账号当成未登录。
          syncTraeUsertag(decoded, traeAuth!);
          final pretty = original.contains('\n')
              ? const JsonEncoder.withIndent('\t').convert(decoded)
              : jsonEncode(decoded);
          DesktopClient.writeAtomic(file, pretty);
        } else {
          final next = buildWorkbuddyInfo(decoded.cast<String, dynamic>(), workbuddyPayload!, protectorKey!);
          DesktopClient.writeAtomic(file, jsonEncode(next));
        }
      }

      if (!restart) {
        return DesktopSwitchResult(
          ok: true,
          message: '已切换到 $displayName，请手动启动 ${provider.label} 客户端',
        );
      }
      if (executable == null) {
        return DesktopSwitchResult(ok: true, message: '已切换到 $displayName，未找到主程序，请手动启动客户端');
      }
      onPhase?.call('正在启动 ${provider.label} 客户端…');
      await DesktopClient.launch(executable);
      return DesktopSwitchResult(
        ok: true,
        message: '已切换到 $displayName，${provider.label} 客户端正在重新启动',
      );
    } catch (error) {
      // 已经关掉客户端却写入失败时，把客户端拉起来，避免用户以为程序被弄坏。
      if (stopped && executable != null) {
        try {
          await DesktopClient.launch(executable);
        } catch (_) {
          // 忽略：原始错误更重要
        }
      }
      return DesktopSwitchResult(ok: false, message: _message(error));
    }
  }

  static String _message(Object error) {
    if (error is FormatException) return '登录态格式异常：${error.message}';
    if (error is FileSystemException) return '文件操作失败：${error.message}';
    return error.toString();
  }

  /// Trae 账号库里的凭据本身就是 `tc` 容器，写回客户端前先解密校验一次。
  static Map<String, dynamic> _traeAuth(String credential) {
    final auth = TraeCrypto.decrypt(credential);
    if (auth['userId'] == null) throw const FormatException('Trae 登录态缺少 userId');
    return auth;
  }

  static const String _traeUserTagKey = 'iCubeAuthInfo://usertag';

  /// 补齐客户端校验登录态时依赖的账号字段。
  ///
  /// 客户端 `UserInfoManager` 的第一道判断是 `if (!userInfo.account.scope) return`
  /// ——scope 为空会直接被当成未登录（即使 token 有效）。而应用自己的登录流程
  /// 走的是 GetUserInfo，部分账号不返回 Scope / LoginScope / StoreRegion / UserTag，
  /// 写进客户端后就表现为「切过去客户端又弹登录」。这里按客户端自身写入的默认值补齐。
  static Map<String, dynamic> normalizeTraeAuth(Map<String, dynamic> auth) {
    final rawAccount = auth['account'];
    if (rawAccount is! Map) return auth;
    final account = Map<String, dynamic>.from(rawAccount);

    var region = '';
    final userRegion = auth['userRegion'];
    if (userRegion is Map) {
      region = (userRegion['region'] ?? userRegion['_aiRegion'] ?? '').toString();
    }
    if (region.isEmpty) region = 'CN';

    void fill(String key, String value) {
      final current = account[key];
      if (current == null || current.toString().isEmpty) account[key] = value;
    }

    fill('scope', 'marscode');
    fill('loginScope', 'trae');
    fill('storeRegion', region);
    fill('storeCountryCode', '');
    fill('storeCountrySrc', '');
    fill('userTag', 'cn');
    account.putIfAbsent('migrateToSG', () => false);
    auth['account'] = account;
    return auth;
  }

  /// 把目标账号补进 `iCubeAuthInfo://usertag`（userId → 地区）。
  ///
  /// 客户端的地区判定依赖这张表：缺少目标 userId 时，即使 token 有效也会被当成
  /// 未登录，表现为「切换到某个账号后客户端又弹登录」。
  static void syncTraeUsertag(Map<dynamic, dynamic> storage, Map<String, dynamic> auth) {
    final raw = storage[_traeUserTagKey];
    final userId = auth['userId']?.toString();
    if (raw == null || userId == null || userId.isEmpty) return;

    final text = raw.toString();
    final plain = text.trimLeft().startsWith('{');
    Map<String, dynamic> regionMap;
    try {
      final decoded = plain ? jsonDecode(text) : TraeCrypto.decrypt(text);
      if (decoded is! Map) return;
      regionMap = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 解不开就保持原样，避免把客户端登录态写坏
      return;
    }

    var region = (regionMap[userId]?.toString() ?? '').toLowerCase();
    if (region.isEmpty) {
      final userRegion = auth['userRegion'];
      if (userRegion is Map && userRegion['region'] != null) {
        region = userRegion['region'].toString().toLowerCase();
      }
    }
    if (region.isEmpty) region = 'cn';
    regionMap[userId] = region;

    storage[_traeUserTagKey] = plain ? jsonEncode(regionMap) : TraeCrypto.encrypt(regionMap);
  }

  /// WorkBuddy 账号库里是明文 `{account, auth, snapshot}`。
  static Map<String, dynamic> _workbuddyPayload(String credential) {
    final decoded = jsonDecode(credential);
    if (decoded is! Map) throw const FormatException('WorkBuddy 账号凭据格式异常');
    final payload = decoded.cast<String, dynamic>();
    if (payload['account'] is! Map || payload['auth'] is! Map) {
      throw const FormatException('WorkBuddy 账号凭据缺少 account / auth');
    }
    final token = (payload['auth'] as Map)['accessToken'];
    if (token == null || token.toString().isEmpty) {
      throw const FormatException('WorkBuddy 账号凭据缺少 accessToken，请重新登录该账号');
    }
    return payload;
  }

  // ---------------------------------------------------------------------------
  // WorkBuddy 登录态组装
  // ---------------------------------------------------------------------------

  static Future<Uint8List> _readProtectorKey(String executable) async {
    const probe = 'const n=process._linkedBinding("electron_browser_workbuddy_storage");'
        'const o=JSON.parse(String(n.loggerGet()));'
        'process.stdout.write("WB_PROBE_JSON:"+JSON.stringify({version:o.version,atRestSecretKey:o.atRestSecretKey}))';
    final result = await Process.run(
      executable,
      ['-e', probe],
      environment: {'ELECTRON_RUN_AS_NODE': '1'},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final match = RegExp(r'WB_PROBE_JSON:(\{[^\n]*\})').firstMatch((result.stdout as String?) ?? '');
    if (match == null) {
      final stderr = ((result.stderr as String?) ?? '').trim();
      throw StateError('未能从客户端取得解密密钥${stderr.isEmpty ? '' : '：${stderr.substring(stderr.length > 200 ? stderr.length - 200 : 0)}'}');
    }
    final payload = jsonDecode(match.group(1)!) as Map<String, dynamic>;
    final secret = payload['atRestSecretKey'];
    if (payload['version'] != 1 || secret is! String) throw StateError('客户端返回的密钥载荷异常');
    return WbEnvelope.deriveKey(secret);
  }

  /// 用目标账号替换现网登录态，保留原文件的其余结构与键顺序。
  ///
  /// 公开给 `tool/` 下的校验脚本与测试复用，客户端写入前不做额外裁剪。
  static Map<String, dynamic> buildWorkbuddyInfo(
    Map<String, dynamic> live,
    Map<String, dynamic> credential,
    Uint8List key,
  ) {
    final account = (credential['account'] as Map).cast<String, dynamic>();
    final auth = (credential['auth'] as Map).cast<String, dynamic>();
    final liveAccount = live['account'] is Map ? (live['account'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    final liveAuth = live['auth'] is Map ? (live['auth'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    final accounts = live['accounts'] is List ? (live['accounts'] as List) : const [];
    final allAccounts = live['allAccounts'] is List ? (live['allAccounts'] as List) : const [];
    final snapshot = credential['snapshot'] is Map ? (credential['snapshot'] as Map) : const {};
    final snapshotAccounts = snapshot['accounts'] is List ? (snapshot['accounts'] as List) : const [];

    Map<String, dynamic>? templateSlim;
    for (final entry in accounts) {
      if (entry is Map && entry['uid'] == liveAccount['uid']) {
        templateSlim = entry.cast<String, dynamic>();
        break;
      }
    }
    templateSlim ??= accounts.isNotEmpty && accounts.first is Map
        ? (accounts.first as Map).cast<String, dynamic>()
        : allAccounts.isNotEmpty && allAccounts.first is Map
            ? (allAccounts.first as Map).cast<String, dynamic>()
            : snapshotAccounts.isNotEmpty && snapshotAccounts.first is Map
                ? (snapshotAccounts.first as Map).cast<String, dynamic>()
                : null;

    final slim = _buildSlimAccount(account, templateSlim, key);
    final next = Map<String, dynamic>.from(live);
    next['account'] = _buildAccount(account, liveAccount, key);
    next['auth'] = _buildAuth(auth, liveAuth, key);
    next['accounts'] = _replaceEntries(accounts, liveAccount['uid'], slim);
    next['allAccounts'] = _replaceEntries(allAccounts, liveAccount['uid'], slim);
    return next;
  }

  static Map<String, dynamic> _union(Map<String, dynamic>? template, Map<String, dynamic> override) {
    final result = <String, dynamic>{};
    for (final entry in (template ?? const {}).entries) {
      result[entry.key] = override[entry.key] ?? entry.value;
    }
    for (final entry in override.entries) {
      result.putIfAbsent(entry.key, () => entry.value);
    }
    return result;
  }

  static Map<String, dynamic> _buildAccount(
    Map<String, dynamic> target,
    Map<String, dynamic> template,
    Uint8List key,
  ) {
    final result = _union(template.isEmpty ? null : template, target)
      ..['uid'] = target['uid']
      ..['lastLogin'] = true;
    return _wrapAccount(result, target, key);
  }

  static Map<String, dynamic> _buildSlimAccount(
    Map<String, dynamic> target,
    Map<String, dynamic>? template,
    Uint8List key,
  ) {
    final source = template ?? target;
    final result = <String, dynamic>{};
    // 有模板时严格按模板的键集合输出，避免把客户端已裁掉的键写回去。
    for (final field in source.keys) {
      result[field] = target[field] ?? source[field];
    }
    if (template == null) {
      for (final entry in target.entries) {
        result.putIfAbsent(entry.key, () => entry.value);
      }
    }
    result['uid'] = target['uid'];
    result['lastLogin'] = true;
    return _wrapAccount(result, target, key);
  }

  static Map<String, dynamic> _wrapAccount(
    Map<String, dynamic> object,
    Map<String, dynamic> target,
    Uint8List key,
  ) {
    if (object.containsKey('nickname')) {
      object['nickname'] = WbEnvelope.seal(target['nickname']?.toString() ?? '', key);
    }
    if (object.containsKey('phoneNumber')) {
      object['phoneNumber'] = WbEnvelope.seal(
        WbEnvelope.maskPhone(target['phoneNumber']?.toString() ?? ''),
        key,
      );
    }
    return object;
  }

  static Map<String, dynamic> _buildAuth(
    Map<String, dynamic> target,
    Map<String, dynamic> template,
    Uint8List key,
  ) {
    final result = _union(template.isEmpty ? null : template, target);
    result['accessToken'] = target['accessToken'];
    final refreshToken = target['refreshToken'];
    if (refreshToken != null && refreshToken.toString().isNotEmpty) {
      result['refreshToken'] = refreshToken;
    } else {
      result.remove('refreshToken');
    }
    result['lastRefreshTime'] = target['lastRefreshTime'] ??
        template['lastRefreshTime'] ??
        DateTime.now().millisecondsSinceEpoch;
    result['accessToken'] = WbEnvelope.seal(result['accessToken'].toString(), key);
    if (result['refreshToken'] != null) {
      result['refreshToken'] = WbEnvelope.seal(result['refreshToken'].toString(), key);
    }
    return result;
  }

  static List<dynamic> _replaceEntries(List<dynamic> list, Object? oldUid, Map<String, dynamic> slim) {
    if (list.isEmpty) return [slim];
    var replaced = false;
    final result = <dynamic>[];
    for (final entry in list) {
      if (entry is Map && entry['uid'] == oldUid) {
        replaced = true;
        result.add(slim);
      } else if (entry is Map) {
        result.add({...entry.cast<String, dynamic>(), 'lastLogin': false});
      } else {
        result.add(entry);
      }
    }
    if (!replaced) result.insert(0, slim);
    return result;
  }

}
