import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/screens/schedules_screen.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 定时任务页：手机窄屏不溢出，能展示每个账号的定时与上次结果。
void main() {
  testWidgets('窄屏展示定时任务与执行情况', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(() async {
      final appState = AppState();
      await appState.init(
        database: await AppDatabase.openInMemory(),
        startScheduler: false,
        refreshOnStart: false,
        syncBackground: false,
        importDesktopAccounts: false,
      );
      final id = await appState.db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: 'uid-1',
        displayName: '测试账号',
        endpoint: 'https://example.com',
        credential: '',
      );
      await appState.db.updateSchedule(id, enabled: true, time: '09:00');
      await appState.reload();
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
          child: const SchedulesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('定时任务'), findsOneWidget);
    expect(find.text('测试账号'), findsWidgets);
    expect(find.text('每日 09:00'), findsOneWidget);
    expect(find.textContaining('下次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
