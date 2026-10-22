import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/services/http_json.dart';
import 'package:checkin_hub/src/services/qoder/qoder_browser_cookie.dart';
import 'package:checkin_hub/src/services/qoder/qoder_web_usage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Qoder 网页端用量：把 qoder.cn 的逐笔记录映射成用量条目，并按 user_id 归属账号。
void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    QoderWebUsage.clearCaches();
  });

  tearDown(() async {
    await db.close();
  });

  Future<Map<String, Object?>> accountRow(String uid, {String name = 'Qoder 主号'}) async {
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

  test('逐笔明细映射为用量条目', () async {
    final row = await accountRow('u-1');
    final calls = <String>[];
    final web = QoderWebUsage(
      db,
      request: (url, headers) async {
        calls.add(url);
        if (url.contains('/histories')) {
          return json({
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
        }
        return json({
          'user_id': 'u-1',
          'plan_quota': {
            'quota_summary': {'used_value': 7, 'limit_value': 20, 'remaining_value': 13},
          },
        });
      },
    );
    await web.saveManualCookie('qoder_session_cookie=abc');

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

    // 未计费的那条带上计费类型，避免和正常请求混淆。
    final free = result.entries.firstWhere((entry) => entry.sessionId == 's-1');
    expect(free.credits, 0);
    expect(free.title, 'Agent · Not Charged');
    expect(calls.any((url) => url.contains('start_time=')), isTrue);
  });

  test('登录态不属于该账号时回落到 null', () async {
    final row = await accountRow('u-2');
    final web = QoderWebUsage(
      db,
      request: (url, headers) async => json({
        'user_id': 'other-user',
        'data': [],
        'page_result': {'last_page': 1},
      }),
    );
    await web.saveManualCookie('qoder_session_cookie=abc');
    expect(await web.queryForAccount(row, days: 7), isNull);
  });

  test('手动 Cookie 优先于浏览器登录态', () async {
    var browserRead = false;
    final web = QoderWebUsage(
      db,
      browserLoader: () async {
        browserRead = true;
        return const [
          QoderBrowserSession(
            cookie: 'from=browser',
            browser: 'Chrome',
            dbPath: '/tmp/Cookies',
          ),
        ];
      },
    );
    await web.saveManualCookie('qoder_session_cookie=manual');

    final session = await web.session();
    expect(session, isNotNull);
    expect(session!.cookie, 'qoder_session_cookie=manual');
    expect(session.source, '手动 Cookie');
    expect(browserRead, isFalse);
    expect(web.browserSupported, isTrue);
  });

  test('probe 报告浏览器登录态与归属账号', () async {
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'qoder_session_cookie=abc',
          browser: 'Chrome',
          dbPath: '/tmp/Cookies',
        ),
      ],
      request: (url, headers) async => json({
        'user_id': 'u-3',
        'plan_quota': {
          'quota_summary': {'used_value': 1, 'limit_value': 10, 'remaining_value': 9},
        },
      }),
    );

    final state = await web.probe();
    expect(state.available, isTrue);
    expect(state.source, 'Chrome 浏览器');
    expect(state.fromBrowser, isTrue);
    expect(state.userId, 'u-3');
    expect(state.error, isEmpty);
  });

  test('登录态失效时 probe 给出可读原因', () async {
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'qoder_session_cookie=expired',
          browser: 'Chrome',
          dbPath: '/tmp/Cookies',
        ),
      ],
      request: (url, headers) async => json({'message': 'unauthorized'}, status: 401),
    );

    final state = await web.probe();
    expect(state.available, isFalse);
    expect(state.error, contains('重新登录'));
  });

  test('浏览器登录态读取失败时给出提示', () async {
    final web = QoderWebUsage(
      db,
      browserLoader: () async =>
          throw QoderCookieException('未找到 Chrome / Chromium / Edge 的 Cookies 库'),
    );
    final state = await web.probe();
    expect(state.available, isFalse);
    expect(state.source, '未配置');
    expect(state.error, contains('Cookies 库'));
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

  test('用量明细优先使用账号绑定的 Cookie', () async {
    final row = await accountRow('uid-c');
    final seen = <String>[];
    final web = QoderWebUsage(
      db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'cookie=browser',
          browser: 'Chrome',
          dbPath: '/c1',
        ),
      ],
      request: (url, headers) async {
        seen.add(headers['Cookie'] ?? '');
        if (url.contains('/histories')) {
          return json({
            'data': [
              {
                'begin_at': 1792640563759,
                'model_category': 'Qwen3.8-Flash',
                'operation': 'Agent',
                'kind': 'Charged',
                'credits': 1.5,
                'session_id': 's-1',
              },
            ],
            'page_result': {'last_page': 1},
          });
        }
        return json({'user_id': 'uid-c'});
      },
    );

    await web.bindCookie(row['id'] as int, 'cookie=bound', uid: 'uid-c');
    final result = await web.queryForAccount(row, days: 7);
    expect(result, isNotNull);
    expect(result!.entries, hasLength(1));
    expect(seen, isNotEmpty);
    expect(seen.every((cookie) => cookie == 'cookie=bound'), isTrue);
  });

  test('已绑定账号时即使浏览器没登录态也算可用', () async {
    final row = await accountRow('uid-d');
    final web = QoderWebUsage(
      db,
      browserLoader: () async =>
          throw QoderCookieException('未找到 Chrome / Chromium / Edge 的 Cookies 库'),
    );
    await web.bindCookie(row['id'] as int, 'cookie=x', uid: 'uid-d');

    final state = await web.probe();
    expect(state.boundAccounts, 1);
    expect(state.available, isTrue);
    expect(state.source, '账号已绑定');
  });
}
