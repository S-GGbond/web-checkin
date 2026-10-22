import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/services/http_json.dart';
import 'package:checkin_hub/src/services/qoder/qoder_browser_cookie.dart';
import 'package:checkin_hub/src/services/qoder/qoder_web_usage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Qoder 网页端用量：逐笔记录映射成用量条目，并按 user_id 绑定到账号。
void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    QoderWebUsage.clearCaches();
  });

  tearDown(() async {
    await db.close();
  });

  Future<Map<String, Object?>> accountRow(
    String uid, {
    String name = 'Qoder 主号',
  }) async {
    await db.upsertAccount(
      provider: PlatformKind.qoder,
      externalId: uid,
      displayName: name,
      endpoint: 'https://openapi.qoder.com.cn',
      credential: '{}',
    );
    final rows = await db.listAccountRows();
    return rows.firstWhere((row) => row['external_id'] == uid);
  }

  JsonResult json(Object body, {int status = 200}) =>
      JsonResult(status, (body as Map).cast<String, dynamic>());

  JsonResult historyPayload() => json({
        'data': [
          {
            'begin_at': 1792640563759,
            'model_category': 'Qwen3.8-Flash',
            'source': 'Qoder',
            'operation': 'Agent',
            'kind': 'Not Charged',
            'credits': 0,
            'original_credits': 0.12,
            'cost': 0,
            'original_cost': 0,
            'session_id': 's-1',
          },
          {
            'begin_at': 1792640000000,
            'model_category': 'DeepSeek-Flash',
            'source': 'Qoder',
            'operation': 'Agent',
            'kind': 'Charged',
            'credits': 2.5,
            'original_credits': 2.5,
            'session_id': 's-2',
          },
        ],
        'page_result': {'last_page': 1},
      });

  test('逐笔明细映射为用量条目', () async {
    final row = await accountRow('u-1');
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [],
      request: (url, headers) async => url.contains('/histories')
          ? historyPayload()
          : json({'user_id': 'u-1'}),
    );
    await web.bindCookie(row['id'] as int, 'cookie=bound', uid: 'u-1');

    final result = await web.queryForAccount(row, days: 7);
    expect(result, isNotNull);
    expect(result!.entries, hasLength(2));

    final charged = result.entries.firstWhere((entry) => entry.sessionId == 's-2');
    expect(charged.provider, PlatformKind.qoder);
    expect(charged.model, 'DeepSeek-Flash');
    expect(charged.credits, 2.5);
    expect(charged.client, 'Qoder');
    expect(charged.title, 'Agent');
    expect(charged.accountName, 'Qoder 主号');

    final free = result.entries.firstWhere((entry) => entry.sessionId == 's-1');
    expect(free.credits, 0);
    expect(free.title, 'Agent · Not Charged');
  });

  test('登录态不属于该账号时返回 null', () async {
    final row = await accountRow('u-2');
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'cookie=someone',
          browser: 'Chrome',
          dbPath: '/tmp/Cookies',
        ),
      ],
      request: (url, headers) async => json({'user_id': 'other-user'}),
    );

    expect(await web.queryForAccount(row, days: 7), isNull);
    expect(await web.boundCookie(row['id'] as int), isEmpty);
  });

  test('归属匹配时顺手绑定，之后不再依赖浏览器', () async {
    final row = await accountRow('u-3');
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'cookie=match',
          browser: 'Chrome',
          dbPath: '/tmp/Cookies',
        ),
      ],
      request: (url, headers) async => url.contains('/histories')
          ? historyPayload()
          : json({'user_id': 'u-3'}),
    );

    final result = await web.queryForAccount(row, days: 7);
    expect(result, isNotNull);
    expect(await web.boundCookie(row['id'] as int), 'cookie=match');
  });

  test('抓取时按 user_id 绑定到对应账号', () async {
    final first = await accountRow('uid-a', name: 'Qoder A');
    final second = await accountRow('uid-b', name: 'Qoder B');
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'cookie=one',
          browser: 'Chrome',
          dbPath: '/c1',
        ),
        QoderBrowserSession(
          cookie: 'cookie=two',
          browser: 'Chromium',
          dbPath: '/c2',
        ),
      ],
      request: (url, headers) async {
        if (url.contains('/histories')) {
          return json({'data': [], 'page_result': {'last_page': 1}});
        }
        final cookie = headers['Cookie'] ?? '';
        return json({'user_id': cookie.contains('two') ? 'uid-b' : 'uid-a'});
      },
    );

    expect(await web.captureAll(), 2);
    expect(await web.boundCookie(first['id'] as int), 'cookie=one');
    expect(await web.boundCookie(second['id'] as int), 'cookie=two');
    expect(await web.boundAccountCount(), 2);
  });

  test('已绑定账号时即使浏览器没有登录态也能查明细', () async {
    final row = await accountRow('uid-d');
    final web = QoderWebUsage(
      db,
      browserLoader: () async =>
          throw QoderCookieException('未找到 Chrome / Chromium / Edge 的 Cookies 库'),
      request: (url, headers) async => url.contains('/histories')
          ? historyPayload()
          : json({'user_id': 'uid-d'}),
    );
    await web.bindCookie(row['id'] as int, 'cookie=bound', uid: 'uid-d');

    final result = await web.queryForAccount(row, days: 7);
    expect(result, isNotNull);
    expect(result!.entries, hasLength(2));
  });

  test('绑定的 Cookie 失效时解绑并回落', () async {
    final row = await accountRow('uid-e');
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [],
      request: (url, headers) async => json({'message': 'unauthorized'}, status: 401),
    );
    await web.bindCookie(row['id'] as int, 'cookie=expired', uid: 'uid-e');

    expect(await web.queryForAccount(row, days: 7), isNull);
    expect(await web.boundCookie(row['id'] as int), isEmpty);
  });
}
