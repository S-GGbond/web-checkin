import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/screens/accounts_screen.dart';
import 'package:checkin_hub/src/services/desktop/desktop_switch_service.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Qoder 客户端状态：探测完成后要显示当前登录账号，不能一直停在「检测中」。
void main() {
  Future<AppState> buildState(WidgetTester tester) async {
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
        externalId: 'qoder-uid-1',
        displayName: 'aliyun9646108344',
        endpoint: 'https://openapi.qoder.com.cn',
        credential: '{}',
      );
      await state.reload(notify: false);
      return state;
    }))!;
  }

  Widget wrap(AppState state) => MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, inner) => AppTokensScope(
          palette: AppPalette.dark,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const Scaffold(body: AccountsScreen()),
        ),
      );

  testWidgets('Qoder 分组显示客户端当前账号而不是检测中', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = await buildState(tester);
    state.desktopClients[PlatformKind.qoder] = const DesktopClientInfo(
      provider: PlatformKind.qoder,
      authFiles: ['/home/user/.config/com.qodercn.app.stable/auth.v1.dat'],
      executable: '/usr/bin/qoder-cn',
      activeExternalId: 'qoder-uid-1',
    );

    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    expect(find.text('检测中'), findsNothing);
    expect(find.text('正在检测客户端…'), findsNothing);
    expect(find.textContaining('客户端当前：aliyun9646108344'), findsOneWidget);
    expect(find.text('已就绪'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(state.db.close);
  });

  testWidgets('Qoder 没有登录态时提示未检测到', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = await buildState(tester);
    state.desktopClients[PlatformKind.qoder] = const DesktopClientInfo(
      provider: PlatformKind.qoder,
      authFiles: [],
      executable: '/usr/bin/qoder-cn',
      activeExternalId: null,
    );

    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    expect(find.text('检测中'), findsNothing);
    expect(find.textContaining('未检测到 Qoder 客户端登录态'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.runAsync(state.db.close);
  });
}
