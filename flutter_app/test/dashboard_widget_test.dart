import 'package:checkin_hub/src/app.dart';
import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 渲染真实概览页，覆盖宽/窄两种窗口。
/// 这类测试能捕获 `flutter analyze` 看不到的布局溢出与祖先依赖缺失问题。
void main() {
  Future<AppState> buildState({bool withAccounts = true}) async {
    final db = await AppDatabase.openInMemory();
    if (withAccounts) {
      final workbuddyId = await db.upsertAccount(
        provider: PlatformKind.workbuddy,
        externalId: 'wb-1',
        displayName: '我的 WorkBuddy',
        endpoint: 'https://www.workbuddy.cn',
        credential: '{"auth":{},"account":{},"snapshot":{}}',
        label: '工作',
      );
      await db.updateStatus(workbuddyId, {
        'active': true,
        'today_checked_in': true,
        'usage': {'creditsTotal': 1000, 'creditsLeft': 640, 'creditsUsed': 360, 'unlimited': false},
      });
      await db.updateCheckin(workbuddyId, ok: true, message: '签到成功');
      await db.addLog(workbuddyId, PlatformKind.workbuddy, action: 'claim', ok: true, message: '签到成功');

      final traeId = await db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: 'trae-1',
        displayName: '我的 Trae',
        endpoint: 'https://api.trae.cn',
        credential: 'ignored',
      );
      await db.updateStatus(traeId, {
        'checked_in': false,
        'usage': {'creditsTotal': 500, 'creditsLeft': 120, 'creditsUsed': 380, 'unlimited': false},
      });
      await db.addLog(traeId, PlatformKind.trae, action: 'status', ok: false, message: '登录态已过期');
    }

    final state = AppState();
    await state.init(database: db, startScheduler: false, refreshOnStart: false, syncBackground: false);
    await state.reload();
    return state;
  }

  Widget wrap(AppState state) =>
      ChangeNotifierProvider<AppState>.value(value: state, child: const HubMaterialApp());

  testWidgets('宽窗口渲染概览页与账号卡片', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(buildState))!;
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    expect(find.text('签到中枢'), findsWidgets);
    expect(find.text('托管账号'), findsWidgets);
    expect(find.text('今日已签到'), findsWidgets);

    // 账号卡片与动态列表在首屏之下，滚动后再断言。
    await tester.dragUntilVisible(
      find.text('我的 WorkBuddy'),
      find.byType(ListView).first,
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的 WorkBuddy'), findsWidgets);
    expect(find.text('640 / 1000'), findsWidgets);

    await tester.dragUntilVisible(
      find.textContaining('登录态已过期'),
      find.byType(ListView).first,
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('登录态已过期'), findsWidgets);
  });

  testWidgets('窄窗口使用底部导航且不溢出', (tester) async {
    tester.view.physicalSize = const Size(400, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(buildState))!;
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('概览'), findsWidgets);
    expect(find.text('签到中枢'), findsWidgets);

    // 窄屏下账号卡片位于首屏之下，滚动后确认渲染正常且无溢出。
    await tester.dragUntilVisible(
      find.text('我的 WorkBuddy'),
      find.byType(ListView).first,
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的 WorkBuddy'), findsWidgets);
  });

  testWidgets('无账号时概览仍展示完整结构与引导', (tester) async {
    // 用窄窗口覆盖引导卡的紧凑布局（换行 + 全宽按钮）。
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(() => buildState(withAccounts: false)))!;
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    // 头部与指标卡依然渲染，不是空白页。
    expect(find.text('签到中枢'), findsWidgets);
    expect(find.text('托管账号'), findsWidgets);
    expect(find.text('0 / 0'), findsWidgets);

    // 引导卡在首屏之下，滚动后确认存在。
    await tester.dragUntilVisible(
      find.text('还没有托管账号，先添加一个'),
      find.byType(ListView).first,
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有托管账号，先添加一个'), findsOneWidget);
    expect(find.text('添加账号'), findsWidgets);
  });

  testWidgets('可切换到动态页并按平台筛选', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(buildState))!;
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('动态'));
    await tester.pumpAndSettle();

    expect(find.text('执行动态'), findsOneWidget);
    expect(find.text('签到成功'), findsWidgets);
    expect(find.text('登录态已过期'), findsWidgets);

    await tester.tap(find.text('仅失败'));
    await tester.pumpAndSettle();

    expect(find.text('登录态已过期'), findsWidgets);
    expect(find.text('签到成功'), findsNothing);
  });
}
