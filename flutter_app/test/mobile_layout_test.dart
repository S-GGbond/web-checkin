import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/screens/accounts_screen.dart';
import 'package:checkin_hub/src/screens/dashboard_screen.dart';
import 'package:checkin_hub/src/screens/settings_screen.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 手机窄屏（360dp）下三个主页面都不能出现布局溢出。
void main() {
  Future<AppState> buildState(WidgetTester tester) async {
    return (await tester.runAsync(() async {
      final appState = AppState();
      await appState.init(
        database: await AppDatabase.openInMemory(),
        startScheduler: false,
        refreshOnStart: false,
        syncBackground: false,
        importDesktopAccounts: false,
      );
      await appState.db.upsertAccount(
        provider: PlatformKind.workbuddy,
        externalId: 'u-1',
        displayName: '158****7171',
        endpoint: 'https://example.com',
        credential: '',
      );
      await appState.db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: 'u-2',
        displayName: 'Trae 账号',
        endpoint: 'https://example.com',
        credential: '',
      );
      await appState.reload();
      return appState;
    }))!;
  }

  Widget wrap(AppState state, Widget child) {
    return MaterialApp(
      theme: AppTheme.dark(),
      builder: (context, inner) => AppTokensScope(
        palette: AppPalette.dark,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: ChangeNotifierProvider<AppState>.value(value: state, child: child),
    );
  }

  testWidgets('账号页窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = await buildState(tester);

    await tester.pumpWidget(
      wrap(state, const Scaffold(body: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('托管账号'), findsOneWidget);
    expect(find.text('刷新状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('概览页窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = await buildState(tester);

    await tester.pumpWidget(
      wrap(state, Scaffold(body: DashboardScreen(onNavigate: (_) {}))),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = await buildState(tester);

    await tester.pumpWidget(
      wrap(state, const Scaffold(body: SettingsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('导出账号（JSON）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
