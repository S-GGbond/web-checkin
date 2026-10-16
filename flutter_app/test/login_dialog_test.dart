import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/models/login_session.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:checkin_hub/src/widgets/login_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 对话框里有无限旋转的进度指示器，不能用 pumpAndSettle，
/// 否则会一直等待动画结束。
Future<void> _pumpTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Widget _host(AppState state, LoginSession session) {
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => LoginDialog.show(context, session),
              child: const Text('打开登录'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('登录对话框可以关闭，且后台登录会话保留', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final session = LoginSession(
      id: 'workbuddy-test',
      provider: PlatformKind.workbuddy,
      authUrl: 'https://www.workbuddy.cn/login?platform=workbuddy&state=test',
    );
    state.activeLogins.add(session);

    await tester.pumpWidget(_host(state, session));
    await tester.tap(find.text('打开登录'));
    await _pumpTransition(tester);
    expect(find.text('登录 WorkBuddy'), findsOneWidget);

    // 右上角关闭按钮必须能退出等待。
    await tester.tap(find.byIcon(Icons.close_rounded));
    await _pumpTransition(tester);

    expect(find.text('登录 WorkBuddy'), findsNothing);
    expect(find.textContaining('登录在后台继续'), findsOneWidget);
    // 关闭对话框不应丢弃会话。
    expect(state.activeLogins, contains(session));
  });

  testWidgets('点击遮罩也能关闭登录对话框', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final session = LoginSession(
      id: 'trae-test',
      provider: PlatformKind.trae,
      authUrl: 'https://www.trae.cn/authorization?client_id=test',
    );
    state.activeLogins.add(session);

    await tester.pumpWidget(_host(state, session));
    await tester.tap(find.text('打开登录'));
    await _pumpTransition(tester);
    expect(find.text('登录 Trae'), findsOneWidget);

    // 点击对话框外部遮罩。
    await tester.tapAt(const Offset(10, 10));
    await _pumpTransition(tester);
    expect(find.text('登录 Trae'), findsNothing);
  });

  testWidgets('等待中会展示授权链接与重开入口', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final session = LoginSession(
      id: 'trae-test-2',
      provider: PlatformKind.trae,
      authUrl: 'https://www.trae.cn/authorization?client_id=abc&code_challenge=xyz',
    );

    await tester.pumpWidget(_host(state, session));
    await tester.tap(find.text('打开登录'));
    await _pumpTransition(tester);

    expect(find.text('等待浏览器授权'), findsOneWidget);
    expect(find.text('重新打开'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('后台等待'), findsOneWidget);
    expect(find.textContaining('code_challenge=xyz'), findsOneWidget);
  });
}
