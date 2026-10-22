import 'dart:io';

import '../../data/app_database.dart';
import '../../models/account.dart';
import '../../models/usage_record.dart';
import '../http_json.dart';
import 'qoder_browser_cookie.dart';

/// Qoder 网页端的一条用量明细（一次请求）。
class QoderWebRecord {
  const QoderWebRecord({
    required this.time,
    required this.model,
    required this.source,
    required this.operation,
    required this.kind,
    required this.credits,
    required this.originalCredits,
    required this.cost,
    required this.originalCost,
    required this.sessionId,
  });

  final DateTime time;
  final String model;
  final String source;
  final String operation;

  /// 计费类型：Not Charged 表示这次没扣积分。
  final String kind;
  final double credits;
  final double originalCredits;
  final double cost;
  final double originalCost;
  final String sessionId;

  bool get charged => credits > 0;
}

/// 区间汇总。
class QoderWebSummary {
  const QoderWebSummary({
    required this.userId,
    required this.usedCredits,
    required this.limitCredits,
    required this.remainingCredits,
  });

  /// 登录态归属的 Qoder userId（额度接口里带回来的）。
  final String userId;
  final double usedCredits;
  final double limitCredits;
  final double remainingCredits;
}

/// 当前可用的网页登录态。
class QoderWebSession {
  const QoderWebSession({
    required this.cookie,
    required this.source,
    required this.fromBrowser,
  });

  final String cookie;

  /// 给界面看的来源说明，例如「Chrome 浏览器」「手动 Cookie」。
  final String source;
  final bool fromBrowser;
}

/// 设置页展示用的状态快照。
class QoderWebState {
  const QoderWebState({
    required this.source,
    required this.userId,
    required this.error,
    required this.fromBrowser,
    required this.available,
    this.boundAccounts = 0,
  });

  final String source;
  final String userId;
  final String error;
  final bool fromBrowser;
  final bool available;

  /// 已经绑定到账号的网页登录态数量。
  final int boundAccounts;
}

/// 一次网页请求：URL + 请求头 → JSON（测试可替换）。
typedef QoderWebRequest = Future<JsonResult> Function(
  String url,
  Map<String, String> headers,
);

/// 读取浏览器登录态（测试可替换）。
typedef QoderBrowserLoader = Future<List<QoderBrowserSession>> Function();

/// Qoder 网页端用量明细（自动复用浏览器登录态）。
///
/// 与 qoder-checkin/web_usage.py 对齐：
///   GET /api/v1/me/usages/big_model_credits/histories → 逐笔用量
///   GET /api/v2/me/usages/big_model_credits           → 额度汇总（含 user_id）
/// 客户端接口（openapi）只有按天热力图；逐笔明细只有网页端有，所以这里走 Cookie。
class QoderWebUsage {
  QoderWebUsage(
    this._db, {
    QoderWebRequest? request,
    QoderBrowserLoader? browserLoader,
  })  : _request = request ?? _httpGet,
        _browserLoader = browserLoader;

  final AppDatabase _db;

  /// 发请求的实现（测试注入用）。
  final QoderWebRequest _request;

  /// 读取浏览器登录态的实现；为空时走本机浏览器。
  final QoderBrowserLoader? _browserLoader;

  static const base = 'https://qoder.cn';
  static const historyPath = '/api/v1/me/usages/big_model_credits/histories';
  static const summaryPath = '/api/v2/me/usages/big_model_credits';
  static const referer = '$base/account/usage?client=qoder&sourceType=IDE';
  static const userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36';
  static const manualKey = 'qoder_web_cookie';
  static const pageSize = 100;
  static const maxPages = 200;

  /// userId 缓存：一次用量加载会给每个账号各查一次，避免重复打接口。
  static ({String cookie, String uid, DateTime at})? _identityCache;

  /// 浏览器登录态缓存：解 Cookie 要读钥匙环 + 拷贝 Cookies 库，别每次都来一遍。
  static ({QoderWebSession session, DateTime at})? _browserCache;

  // ---------------------------------------------------------------------------
  // 登录态
  // ---------------------------------------------------------------------------

  Future<String> manualCookie() async =>
      (await _db.getSetting(manualKey))?.trim() ?? '';

  Future<void> saveManualCookie(String cookie) =>
      _db.setSetting(manualKey, cookie.trim());

  Future<void> clearManualCookie() => _db.setSetting(manualKey, '');

  /// 手动 Cookie 优先；桌面端其次复用浏览器登录态。
  Future<QoderWebSession?> session() async {
    final manual = await manualCookie();
    if (manual.isNotEmpty) {
      return QoderWebSession(
        cookie: manual,
        source: '手动 Cookie',
        fromBrowser: false,
      );
    }
    if (!browserSupported) return null;
    final cached = _browserCache;
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 1)) {
      return cached.session;
    }
    try {
      final found = (await _loadBrowser()).first;
      final session = QoderWebSession(
        cookie: found.cookie,
        source: '${found.browser} 浏览器',
        fromBrowser: true,
      );
      _browserCache = (session: session, at: DateTime.now());
      return session;
    } catch (_) {
      return null;
    }
  }

  /// 设置页用：给出当前登录态、归属账号与失败原因。
  Future<QoderWebState> probe() async {
    final bound = await boundAccountCount();
    final manual = await manualCookie();

    Future<QoderWebState> check(QoderWebSession session) async {
      try {
        final data = await summary(session.cookie);
        return QoderWebState(
          source: session.source,
          userId: data.userId,
          error: '',
          fromBrowser: session.fromBrowser,
          available: true,
          boundAccounts: bound,
        );
      } on ApiException catch (failure) {
        return QoderWebState(
          source: session.source,
          userId: '',
          error: failure.message,
          fromBrowser: session.fromBrowser,
          available: bound > 0,
          boundAccounts: bound,
        );
      }
    }

    if (manual.isNotEmpty) {
      return check(
        QoderWebSession(
          cookie: manual,
          source: '手动 Cookie',
          fromBrowser: false,
        ),
      );
    }
    if (bound > 0 && !browserSupported) {
      return QoderWebState(
        source: '账号已绑定',
        userId: '',
        error: '',
        fromBrowser: false,
        available: true,
        boundAccounts: bound,
      );
    }
    if (!browserSupported) {
      return QoderWebState(
        source: '未配置',
        userId: '',
        error: '当前平台只能手动填写 Cookie',
        fromBrowser: false,
        available: false,
        boundAccounts: bound,
      );
    }
    try {
      final browser = (await _loadBrowser()).first;
      return check(
        QoderWebSession(
          cookie: browser.cookie,
          source: '${browser.browser} 浏览器',
          fromBrowser: true,
        ),
      );
    } on QoderCookieException catch (failure) {
      return QoderWebState(
        source: bound > 0 ? '账号已绑定' : '未配置',
        userId: '',
        error: bound > 0 ? '' : failure.message,
        fromBrowser: false,
        available: bound > 0,
        boundAccounts: bound,
      );
    } catch (failure) {
      return QoderWebState(
        source: bound > 0 ? '账号已绑定' : '未配置',
        userId: '',
        error: bound > 0 ? '' : failure.toString(),
        fromBrowser: false,
        available: bound > 0,
        boundAccounts: bound,
      );
    }
  }

  /// 直接读一次浏览器登录态（设置页的「读取浏览器登录态」按钮）。
  Future<QoderWebSession> readBrowser() async {
    final browser = (await _loadBrowser()).first;
    final session = QoderWebSession(
      cookie: browser.cookie,
      source: '${browser.browser} 浏览器',
      fromBrowser: true,
    );
    _browserCache = (session: session, at: DateTime.now());
    return session;
  }


  // ---------------------------------------------------------------------------
  // 按账号绑定的网页登录态
  //
  // Qoder 客户端的「用量 → 查看详情」只是在浏览器里打开 qoder.cn/account/usage，
  // 网页会话是登录时在浏览器里建立的（app 打开的就是 /users/sign-in）。所以这里
  // 在账号登录完成后立刻从浏览器抓一次，并绑定到刚登录的 user_id，之后按账号各用
  // 各的 Cookie，不再需要浏览器一直保持登录。
  // ---------------------------------------------------------------------------

  static String _cookieKey(int accountId) => 'qoder_web_cookie_$accountId';
  static String _uidKey(int accountId) => 'qoder_web_cookie_uid_$accountId';
  static String _atKey(int accountId) => 'qoder_web_cookie_at_$accountId';

  /// 该账号已绑定的浏览器 Cookie；没有则返回空串。
  Future<String> boundCookie(int accountId) async =>
      (await _db.getSetting(_cookieKey(accountId)))?.trim() ?? '';

  Future<void> unbindCookie(int accountId) async {
    await _db.setSetting(_cookieKey(accountId), '');
    await _db.setSetting(_uidKey(accountId), '');
    await _db.setSetting(_atKey(accountId), '');
  }

  Future<void> bindCookie(
    int accountId,
    String cookie, {
    String uid = '',
  }) async {
    await _db.setSetting(_cookieKey(accountId), cookie.trim());
    await _db.setSetting(_uidKey(accountId), uid);
    await _db.setSetting(
      _atKey(accountId),
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  /// 已绑定的 Qoder 账号数。
  Future<int> boundAccountCount() async {
    var count = 0;
    for (final row in await _db.listAccountRows()) {
      if (row['provider'] != PlatformKind.qoder.id) continue;
      if ((await boundCookie(row['id'] as int? ?? 0)).isNotEmpty) count++;
    }
    return count;
  }

  /// 逐份浏览器登录态查归属，给对应的 Qoder 账号补上绑定。
  ///
  /// [onlyUid] 不为空时只处理这一个账号（登录成功后的自动抓取）。
  Future<int> captureAll({String? onlyUid}) async {
    if (!browserSupported) return 0;
    final rows = (await _db.listAccountRows())
        .where((row) => row['provider'] == PlatformKind.qoder.id)
        .where((row) =>
            onlyUid == null || (row['external_id']?.toString() == onlyUid))
        .toList();
    if (rows.isEmpty) return 0;

    final List<QoderBrowserSession> sessions;
    try {
      sessions = await _loadBrowser();
    } catch (_) {
      return 0;
    }
    // 一份 Cookie 的归属只查一次。
    final owners = <String, String>{};
    var bound = 0;
    for (final row in rows) {
      final id = row['id'] as int? ?? 0;
      final uid = (row['external_id'] ?? '').toString();
      if (id == 0 || uid.isEmpty) continue;
      for (final session in sessions) {
        final owner = owners.putIfAbsent(session.cookie, () => '');
        if (owner.isNotEmpty) {
          if (owner == uid) {
            await bindCookie(id, session.cookie, uid: uid);
            bound++;
            break;
          }
          continue;
        }
        String resolved;
        try {
          resolved = (await summary(session.cookie)).userId;
        } catch (_) {
          resolved = '';
        }
        owners[session.cookie] = resolved;
        if (resolved.isNotEmpty && resolved == uid) {
          await bindCookie(id, session.cookie, uid: uid);
          bound++;
          break;
        }
      }
    }
    return bound;
  }

  /// 登录成功后调用：浏览器里刚完成的登录会写下会话 Cookie，稍有延迟所以重试几次。
  Future<bool> captureForAccount(
    int accountId,
    String uid, {
    int attempts = 4,
    Duration interval = const Duration(seconds: 2),
  }) async {
    if (!browserSupported) return false;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(interval);
      if (await captureAll(onlyUid: uid) > 0) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 接口
  // ---------------------------------------------------------------------------

  Future<JsonResult> _get(String pathAndQuery, String cookie) =>
      _request(base + pathAndQuery, _headers(cookie));

  static Map<String, String> _headers(String cookie) => {
        'Accept': 'application/json, text/plain, */*',
        'Cookie': cookie,
        'Referer': referer,
        'User-Agent': userAgent,
        'X-CSRF-TOKEN': '_echo_csrf_using_sec_fetch_site_',
        'X-Requested-With': 'XMLHttpRequest',
      };

  static Future<JsonResult> _httpGet(String url, Map<String, String> headers) =>
      HttpJson.send(url, method: 'GET', headers: headers);

  /// 登录态归属的 userId；拿不到时返回空串。
  Future<String> userId(String cookie) async {
    final cached = _identityCache;
    if (cached != null &&
        cached.cookie == cookie &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
      return cached.uid;
    }
    final data = await summary(cookie);
    _identityCache = (cookie: cookie, uid: data.userId, at: DateTime.now());
    return data.userId;
  }

  /// 额度汇总：同时带回 user_id，用来判断这份 Cookie 属于哪个账号。
  Future<QoderWebSummary> summary(String cookie) async {
    final result = await _get(summaryPath, cookie);
    _ensureOk(result, '额度');
    final body = result.body;
    final plan =
        (body['plan_quota'] as Map?)?.cast<String, dynamic>() ?? const {};
    final package = (body['resource_package_quota'] as Map?)
            ?.cast<String, dynamic>() ??
        const {};
    final planSummary =
        (plan['quota_summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    final packageSummary =
        (package['quota_summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    return QoderWebSummary(
      userId: (body['user_id'] ?? '').toString(),
      usedCredits:
          _num(planSummary['used_value']) + _num(packageSummary['used_value']),
      limitCredits:
          _num(planSummary['limit_value']) + _num(packageSummary['limit_value']),
      remainingCredits: _num(planSummary['remaining_value']) +
          _num(packageSummary['remaining_value']),
    );
  }

  /// 拉取 [start, end] 之间的逐笔用量；[start] 为空表示不限时间。
  Future<List<QoderWebRecord>> records(
    String cookie, {
    DateTime? start,
    DateTime? end,
  }) async {
    final startMs = start == null
        ? null
        : DateTime(start.year, start.month, start.day).millisecondsSinceEpoch;
    final endMs = end == null
        ? null
        : DateTime(end.year, end.month, end.day)
                .add(const Duration(days: 1))
                .millisecondsSinceEpoch -
            1;

    final out = <QoderWebRecord>[];
    for (var page = 1; page <= maxPages; page++) {
      final query = <String, String>{
        'page': page.toString(),
        'page_size': pageSize.toString(),
        'order_by': 'begin_at',
        'order': '-1',
        if (startMs != null) 'start_time': startMs.toString(),
        if (endMs != null) 'end_time': endMs.toString(),
      };
      final pairs = <String>[];
      query.forEach((key, value) => pairs.add('$key=$value'));
      final result = await _get('$historyPath?${pairs.join('&')}', cookie);
      _ensureOk(result, '用量明细');
      final batch = (result.body['data'] as List?) ?? const [];
      for (final item in batch) {
        if (item is! Map) continue;
        final record = _record(item.cast<String, dynamic>());
        if (record != null) out.add(record);
      }
      final pageResult = (result.body['page_result'] as Map?)
              ?.cast<String, dynamic>() ??
          const {};
      final lastPage = (pageResult['last_page'] as num?)?.toInt() ?? 1;
      if (batch.isEmpty || page >= lastPage) break;
    }
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  static QoderWebRecord? _record(Map<String, dynamic> item) {
    final raw = item['begin_at'] ?? item['time'];
    final millis =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    if (millis <= 0) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(
      millis > 100000000000 ? millis : millis * 1000,
    );
    final credits = _num(item['credits']);
    final original = _num(item['original_credits']);
    if (credits == 0 && original == 0) return null;
    return QoderWebRecord(
      time: time,
      model: (item['model_category'] ?? '').toString(),
      source: (item['source'] ?? '').toString(),
      operation: (item['operation'] ?? '').toString(),
      kind: (item['kind'] ?? '').toString(),
      credits: credits,
      originalCredits: original,
      cost: _num(item['cost']),
      originalCost: _num(item['original_cost']),
      sessionId: (item['session_id'] ?? '').toString(),
    );
  }

  /// 给用量页调用：登录态不属于该账号或不可用时返回 null（调用方回落到热力图）。
  Future<UsageQueryResult?> queryForAccount(
    Map<String, Object?> row, {
    required int days,
  }) async {
    final accountId = row['id'] as int? ?? 0;
    final externalId = (row['external_id'] ?? '').toString();

    // 优先用「登录该账号时自动抓取并绑定」的 Cookie；没有绑定再用全局的手动 /
    // 当前浏览器登录态（还要求归属一致）。
    final bound = await boundCookie(accountId);
    final cookie = bound.isNotEmpty ? bound : (await session())?.cookie ?? '';
    if (cookie.isEmpty) return null;
    try {
      final uid = await userId(cookie);
      if (uid.isNotEmpty && externalId.isNotEmpty && uid != externalId) {
        return null;
      }
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: days - 1));
      final list = await records(cookie, start: start, end: now);
      final name = (row['display_name']?.toString().isNotEmpty ?? false)
          ? row['display_name'].toString()
          : externalId;
      final entries = [
        for (final record in list)
          UsageEntry(
            provider: PlatformKind.qoder,
            accountId: accountId,
            accountName: name,
            time: record.time,
            title: _titleOf(record),
            model: record.model,
            credits: record.credits,
            client: record.source.isEmpty ? 'Qoder' : record.source,
            sessionId: record.sessionId,
          ),
      ];
      return UsageQueryResult(entries: entries, total: entries.length);
    } catch (error) {
      // 绑定的 Cookie 失效就解绑，等下次登录/抓取补上；本次回落到热力图。
      if (bound.isNotEmpty &&
          error is ApiException &&
          error.status == 401) {
        await unbindCookie(accountId);
      }
      return null;
    }
  }

  static String _titleOf(QoderWebRecord record) {
    final operation = record.operation.isEmpty ? 'Qoder 请求' : record.operation;
    if (!record.charged && record.kind.isNotEmpty) {
      return '$operation · ${record.kind}';
    }
    return operation;
  }

  static void _ensureOk(JsonResult result, String what) {
    if (result.status == 401) {
      throw ApiException(
        'Qoder 网页登录态已失效，请在浏览器重新登录 qoder.cn',
        status: 401,
      );
    }
    if (result.status != 200) {
      throw ApiException(
        'Qoder $what 请求失败: HTTP ${result.status}',
        status: result.status,
      );
    }
    final code = result.body['errorCode'];
    if (code != null && code.toString().isNotEmpty) {
      throw ApiException(
        'Qoder $what 返回 $code: ${result.body['errorMessage'] ?? ''}',
      );
    }
  }

  static double _num(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// 清空进程内缓存（测试用）。
  static void clearCaches() {
    _identityCache = null;
    _browserCache = null;
  }

  /// 当前平台（或注入的加载器）能否自动读取浏览器登录态。
  static bool get platformSupportsBrowser => Platform.isLinux || Platform.isMacOS;

  bool get browserSupported => _browserLoader != null || platformSupportsBrowser;

  Future<List<QoderBrowserSession>> _loadBrowser() =>
      (_browserLoader ?? QoderBrowserCookies.loadAll)();
}
