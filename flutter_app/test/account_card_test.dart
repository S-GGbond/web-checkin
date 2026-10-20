import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/theme/app_theme.dart';
import 'package:checkin_hub/src/widgets/account_card.dart';
import 'package:checkin_hub/src/widgets/app_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 账号卡片在桌面端的「点击即切换」与选中边框。
void main() {
  Account account() => Account(
        id: 1,
        provider: PlatformKind.trae,
        externalId: 'u-1',
        displayName: '测试账号',
        label: '',
        endpoint: 'https://api.trae.cn',
        credential: 'credential',
        enabled: true,
        scheduleEnabled: true,
        scheduleTime: '09:00',
        createdAt: 0,
        updatedAt: 0,
      );

  Widget wrap(Widget child) => MaterialApp(
        theme: AppTheme.light(),
        home: AppTokensScope(
          palette: AppPalette.light,
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 360, child: child),
            ),
          ),
        ),
      );

  Widget card({
    required VoidCallback? onSwitchDesktop,
    bool desktopActive = false,
  }) =>
      AccountCard(
        account: account(),
        busy: false,
        onCheckin: () {},
        onRefresh: () {},
        onSchedule: () {},
        onToggleEnabled: (_) {},
        onDelete: () {},
        onSwitchDesktop: onSwitchDesktop,
        desktopActive: desktopActive,
      );

  testWidgets('点击非当前账号的卡片触发切换', (tester) async {
    var switches = 0;
    await tester.pumpWidget(wrap(card(onSwitchDesktop: () => switches++)));
    await tester.tap(find.text('测试账号'));
    await tester.pumpAndSettle();
    expect(switches, 1);
  });

  testWidgets('客户端当前账号带绿色边框且点击不再切换', (tester) async {
    var switches = 0;
    await tester.pumpWidget(
      wrap(card(onSwitchDesktop: () => switches++, desktopActive: true)),
    );

    final surface = tester.widget<SurfaceCard>(find.byType(SurfaceCard));
    expect(surface.borderWidth, greaterThan(1));
    expect(surface.borderColor, AppPalette.light.success);
    expect(surface.onTap, isNull);

    await tester.tap(find.text('测试账号'));
    await tester.pumpAndSettle();
    expect(switches, 0);
  });

  testWidgets('不支持切换的平台（回调为 null）点击卡片不触发任何动作', (tester) async {
    await tester.pumpWidget(wrap(card(onSwitchDesktop: null)));
    final surface = tester.widget<SurfaceCard>(find.byType(SurfaceCard));
    expect(surface.onTap, isNull);
  });
}
