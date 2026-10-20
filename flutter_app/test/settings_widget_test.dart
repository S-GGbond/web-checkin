import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/screens/settings_screen.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 设置页：账号导出/导入入口在，旧的「维护」卡片已下线。
void main() {
  testWidgets('设置页展示账号导出与导入', (tester) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 初始化会读本机文件，必须在 runAsync 里跑，否则假异步会卡住。
    final state = (await tester.runAsync(() async {
      final appState = AppState();
      await appState.init(
        database: await AppDatabase.openInMemory(),
        startScheduler: false,
        refreshOnStart: false,
        syncBackground: false,
        importDesktopAccounts: false,
      );
      return appState;
    }))!;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, inner) => AppTokensScope(
          palette: AppPalette.dark,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('导出账号（JSON）'), findsOneWidget);
    expect(find.text('导入账号（JSON）'), findsOneWidget);
    expect(find.text('维护'), findsNothing);
    expect(find.text('从本机 Trae 客户端导入'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}