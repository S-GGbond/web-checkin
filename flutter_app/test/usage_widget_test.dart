import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/models/usage_record.dart';
import 'package:checkin_hub/src/screens/usage_screen.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用量页：窄屏展示汇总、趋势与会话明细，且不溢出。
void main() {
  testWidgets('用量页窄屏展示汇总与明细', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final result = UsageLoadResult(
      entries: [
        UsageEntry(
          provider: PlatformKind.workbuddy,
          accountId: 1,
          accountName: '158****7171',
          time: now,
          title: '生成签到脚本',
          model: 'deepseek-v4.1-flash',
          credits: 1.5,
          client: 'WorkBuddy',
        ),
        UsageEntry(
          provider: PlatformKind.trae,
          accountId: 2,
          accountName: 'Trae 账号',
          time: now.subtract(const Duration(days: 1)),
          title: '逆向登录链路',
          model: 'claude-sonnet-4.5',
          credits: 2.25,
          client: 'TRAE',
        ),
      ],
      errors: const [],
      total: 2,
      accounts: const [
        UsageAccountRef(
          id: 1,
          name: '158****7171',
          provider: PlatformKind.workbuddy,
        ),
        UsageAccountRef(
          id: 2,
          name: 'Trae 账号',
          provider: PlatformKind.trae,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, inner) => AppTokensScope(
          palette: AppPalette.dark,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: UsageScreen(loader: (_) async => result),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('用量'), findsOneWidget);
    expect(find.text('总消耗'), findsOneWidget);
    expect(find.text('全部账号'), findsOneWidget);
    expect(find.text('3.75'), findsOneWidget);
    expect(find.text('每日消耗'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('生成签到脚本'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('生成签到脚本'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('逆向登录链路'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('逆向登录链路'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('可以只看某个账号', (tester) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final result = UsageLoadResult(
      entries: [
        UsageEntry(
          provider: PlatformKind.workbuddy,
          accountId: 1,
          accountName: '158****7171',
          time: now,
          title: '生成签到脚本',
          model: 'deepseek-v4.1-flash',
          credits: 1.5,
          client: 'WorkBuddy',
        ),
        UsageEntry(
          provider: PlatformKind.trae,
          accountId: 2,
          accountName: 'Trae 账号',
          time: now,
          title: '逆向登录链路',
          model: 'claude-sonnet-4.5',
          credits: 2.25,
          client: 'TRAE',
        ),
      ],
      errors: const [],
      total: 2,
      accounts: const [
        UsageAccountRef(
          id: 1,
          name: '158****7171',
          provider: PlatformKind.workbuddy,
        ),
        UsageAccountRef(
          id: 2,
          name: 'Trae 账号',
          provider: PlatformKind.trae,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, inner) => AppTokensScope(
          palette: AppPalette.dark,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: UsageScreen(loader: (_) async => result)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('158****7171'));
    await tester.pumpAndSettle();

    expect(find.text('1.5'), findsWidgets);
    expect(find.text('3.75'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
