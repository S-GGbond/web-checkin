import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/services/http_json.dart';
import 'package:checkin_hub/src/services/qoder/qoder_browser_cookie.dart';
import 'package:checkin_hub/src/services/qoder/qoder_web_usage.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:checkin_hub/src/widgets/qoder_web_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Qoder 用量明细卡片：窄屏也要说清登录态来源与归属账号。
void main() {
  Future<AppState> buildState(WidgetTester tester, String uid) async {
    return (await tester.runAsync(() async {
      final state = AppState();
      await state.init(
        database: await AppDatabase.openInMemory(),
        startScheduler: false,
        refreshOnStart: false,
        syncBackground: false,
        importDesktopAccounts: false,
      );
      await state.db.upsertAccount(
        provider: PlatformKind.qoder,
        externalId: uid,
        displayName: 'Qoder 主号',
        endpoint: 'https://openapi.qoder.com.cn',
        credential: '{}',
      );
      await state.reload(notify: false);
      return state;
    }))!;
  }

  Widget wrap(AppState state, QoderWebUsage usage) => MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, inner) => AppTokensScope(
          palette: AppPalette.dark,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(AppTokens.space5),
              children: [QoderWebCard(state: state, usage: usage)],
            ),
          ),
        ),
      );

  testWidgets('窄屏展示登录态、归属账号与两个入口', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    QoderWebUsage.clearCaches();

    final state = await buildState(tester, 'u-9');
    final usage = QoderWebUsage(
      state.db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'qoder_session_cookie=abc',
          browser: 'Chrome',
          dbPath: '/tmp/Cookies',
        ),
      ],
      request: (url, headers) async => JsonResult(200, {
        'user_id': 'u-9',
        'plan_quota': {
          'quota_summary': {'used_value': 1, 'limit_value': 9, 'remaining_value': 8},
        },
      }),
    );

    await tester.pumpWidget(wrap(state, usage));
    // 卡片的 probe 要读账号库（真异步），先在真实时间轴上等它跑完再渲染。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.text('Qoder 用量明细'), findsOneWidget);
    expect(find.text('登录态：Chrome 浏览器（归属 Qoder 主号）'), findsOneWidget);
    expect(find.text('立即抓取登录态'), findsOneWidget);
    expect(find.text('手动填写 Cookie'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(state.db.close);
  });

  testWidgets('登录态失效时显示失败原因', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    QoderWebUsage.clearCaches();

    final state = await buildState(tester, 'u-8');
    final usage = QoderWebUsage(
      state.db,
      browserLoader: () async => const [
        QoderBrowserSession(
          cookie: 'qoder_session_cookie=expired',
          browser: 'Chrome',
          dbPath: '/tmp/Cookies',
        ),
      ],
      request: (url, headers) async => JsonResult(401, {'message': 'unauthorized'}),
    );

    await tester.pumpWidget(wrap(state, usage));
    // 卡片的 probe 要读账号库（真异步），先在真实时间轴上等它跑完再渲染。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.textContaining('已失效'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(state.db.close);
  });

  testWidgets('没有登录态时提示未配置', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    QoderWebUsage.clearCaches();

    final state = await buildState(tester, 'u-7');
    final usage = QoderWebUsage(
      state.db,
      browserLoader: () async =>
          throw QoderCookieException('未找到 Chrome / Chromium / Edge 的 Cookies 库'),
    );

    await tester.pumpWidget(wrap(state, usage));
    // 卡片的 probe 要读账号库（真异步），先在真实时间轴上等它跑完再渲染。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.textContaining('未配置'), findsOneWidget);
    expect(find.textContaining('Cookies 库'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(state.db.close);
  });
}
