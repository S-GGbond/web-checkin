import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/models/chat_session.dart';
import 'package:checkin_hub/src/screens/sessions_screen.dart';
import 'package:checkin_hub/src/services/sessions/session_service.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 会话页的渲染：多来源分组、搜索过滤、Trae 预览。
Future<List<ChatMessage>> _noTraeMessages(ChatSession session) async =>
    const [];

void main() {
  late AppState state;

  setUp(() async {
    state = AppState();
    await state.init(
      database: await AppDatabase.openInMemory(),
      startScheduler: false,
      refreshOnStart: false,
      syncBackground: false,
      importDesktopAccounts: false,
    );
  });

  final sessions = <ChatSession>[
    ChatSession(
      provider: PlatformKind.workbuddy,
      accountUid: '',
      workspaceId: '',
      sessionId: '01a1520f-e16b-78f0-a71d-e57030f36ae3',
      title: 'CLI 会话：整理多端适配',
      createdAt: '2026-10-19T02:00:00.000Z',
      lastMessageAt: '2026-10-19T02:30:00.000Z',
      messageCount: 33,
      source: SessionSource.workbuddyCli,
      project: '/home/chen/Project/web-checkin',
    ),
    ChatSession(
      provider: PlatformKind.trae,
      accountUid: '2464446851333947',
      workspaceId: '',
      sessionId: '6acf467e9ffe324bf354afd6',
      title: '请重新生成图片',
      createdAt: '2026-10-19T03:00:00.000Z',
      lastMessageAt: '2026-10-19T03:00:00.000Z',
      messageCount: 20,
      source: SessionSource.trae,
      model: 'claude-sonnet-4.5',
      agent: 'solo_agent',
      preview: '请重新生成图片',
      origin: const ['vscdb', 'snapshot', 'log'],
    ),
    ChatSession(
      provider: PlatformKind.workbuddy,
      accountUid: 'uid-a',
      workspaceId: 'b26da3ac5f8c9e949c9d2977cded8fea',
      sessionId: 'cde6569628584a819669edcf172eed4d',
      title: '桌面端可复制会话',
      createdAt: '2026-10-18T01:00:00.000Z',
      lastMessageAt: '2026-10-18T02:00:00.000Z',
      messageCount: 6,
      project: '/home/chen/Project/web-checkin',
      path: '/tmp/not-used',
    ),
  ];

  SessionScanResult result() => SessionScanResult(
    sessions: sessions,
    workbuddyWorkspaces: 1,
    workbuddyCliSessions: 1,
    traeDatabases: 1,
  );

  Widget wrap(Widget child) {
    return MaterialApp(
      theme: AppTheme.dark(),
      builder: (context, inner) => AppTokensScope(
        palette: AppPalette.dark,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: Scaffold(body: child),
      ),
    );
  }

  testWidgets('多来源会话分组渲染，桌面端才显示勾选框', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(SessionsScreen(
        scanOverride: () async => result(),
        service: SessionService(traeReader: _noTraeMessages),
      )),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('共 3 条 · WorkBuddy 桌面端 1 · CLI 1 · Trae 1'),
      findsOneWidget,
    );
    expect(find.text('CodeBuddy CLI'), findsOneWidget);
    expect(find.text('Trae · 未关联账号'), findsNothing);
    expect(find.text('CLI 会话：整理多端适配'), findsOneWidget);
    expect(find.text('桌面端可复制会话'), findsOneWidget);
    expect(find.text('请重新生成图片'), findsWidgets);
    // 桌面端与 CLI 都可迁移到账号，Trae 可导出迁移包，三条都能勾选。
    expect(find.byType(Checkbox), findsNWidgets(3));
    expect(find.text('导入迁移包'), findsOneWidget);
    expect(find.text('迁移到其他账号…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('勾选 WorkBuddy 会话后可以迁移到其他账号', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(SessionsScreen(
        scanOverride: () async => result(),
        service: SessionService(traeReader: _noTraeMessages),
      )),
    );
    await tester.pumpAndSettle();

    final row = find
        .ancestor(
          of: find.text('桌面端可复制会话'),
          matching: find.byType(Row),
        )
        .first;
    await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();

    expect(find.text('迁移 1 条到账号…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索只保留匹配会话', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(SessionsScreen(
        scanOverride: () async => result(),
        service: SessionService(traeReader: _noTraeMessages),
      )),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'trae');
    await tester.pumpAndSettle();

    expect(find.text('Trae'), findsWidgets);
    expect(find.text('CLI 会话：整理多端适配'), findsNothing);
    expect(find.text('桌面端可复制会话'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口不溢出，Trae 读不到正文时回落到预览', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(SessionsScreen(
        scanOverride: () async => result(),
        service: SessionService(traeReader: _noTraeMessages),
      )),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final traeRow = find
        .ancestor(of: find.text('请重新生成图片').first, matching: find.byType(Row))
        .first;
    await tester.tap(find.descendant(of: traeRow, matching: find.text('查看')));
    await tester.pumpAndSettle();

    expect(find.text('最后一条回复'), findsOneWidget);
    expect(find.text('请重新生成图片'), findsWidgets);
    expect(
      find.textContaining('没能读到这条会话的正文'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
