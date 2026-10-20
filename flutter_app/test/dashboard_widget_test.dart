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
    await state.init(database: db, startScheduler: false, refreshOnStart: false, syncBackground: false,
        importDesktopAccounts: false);
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

  testWidgets('可切换到会话页', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(buildState))!;
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('会话'));
    await tester.pumpAndSettle();

    expect(find.text('执行动态'), findsNothing);
    expect(find.text('会话'), findsWidgets);
    expect(find.text('刷新'), findsWidgets);
  });

  testWidgets('窄窗口会话页布局不溢出', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(buildState))!;
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('会话').first);
    await tester.pumpAndSettle();

    expect(find.text('会话'), findsWidgets);
    expect(find.text('刷新'), findsWidgets);
    expect(find.text('迁移到其他账号…'), findsWidgets);
  });

  testWidgets('账号页在平台分组里展示客户端切换入口', (tester) async {
    // 用窄一些的桌面宽度，顺带压测分组标题里的切换条是否溢出。
    tester.view.physicalSize = const Size(940, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = (await tester.runAsync(buildState))!;
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('账号'));
    await tester.pumpAndSettle();

    // 切换入口跟在 WorkBuddy / Trae 分组标题里，不再单独占一块面板。
    expect(find.text('客户端登录态'), findsNothing);
    expect(find.text('我的 WorkBuddy'), findsWidgets);
    // 切换改成点卡片，不再有下拉框。
    expect(find.byType(DropdownButton<int>), findsNothing);
  });
}
