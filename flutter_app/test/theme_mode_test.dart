import 'package:checkin_hub/src/app.dart';
import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 外观切换：默认跟随系统，切到深色后 MaterialApp 立即变暗。
void main() {
  testWidgets('可以手动切换深色主题', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
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
      return appState;
    }))!;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const HubMaterialApp(),
      ),
    );
    await tester.pumpAndSettle();

    final lightContext = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(lightContext).brightness, Brightness.light);

    await tester.runAsync(() => state.setThemeMode(ThemeMode.dark));
    await tester.pumpAndSettle();

    final darkContext = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(darkContext).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });
}
