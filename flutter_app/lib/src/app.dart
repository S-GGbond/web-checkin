import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'screens/accounts_screen.dart';
import 'screens/sessions_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/settings_screen.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'widgets/account_actions.dart';
import 'widgets/app_widgets.dart';
import 'widgets/responsive.dart';

/// 注入应用状态并启动界面。测试可直接使用 [HubMaterialApp] 搭配自定义状态。
class CheckinHubApp extends StatelessWidget {
  const CheckinHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..init(),
      child: const HubMaterialApp(),
    );
  }
}

/// 主题、本地化与外壳。不依赖具体状态来源，便于 widget 测试直接挂载。
class HubMaterialApp extends StatelessWidget {
  const HubMaterialApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '签到中枢',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        final palette = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
        return AppTokensScope(palette: palette, child: child ?? const SizedBox.shrink());
      },
      home: const HomeShell(),
    );
  }
}

/// 自适应外壳：宽屏用侧边导航轨，窄屏用底部导航栏。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 用户可能去系统设置里授予了精确闹钟权限，回到前台时重新检查。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(context.read<AppState>().refreshExactAlarmPermission());
    }
  }

  static const _destinations = <_Destination>[
    _Destination('概览', Icons.dashboard_rounded, Icons.dashboard_outlined),
    _Destination('账号', Icons.folder_copy_rounded, Icons.folder_copy_outlined),
    _Destination('会话', Icons.forum_rounded, Icons.forum_outlined),
    _Destination('设置', Icons.tune_rounded, Icons.tune_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);

    if (state.fatalError != null) {
      return Scaffold(
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: '初始化失败',
          message: state.fatalError,
        ),
      );
    }
    if (!state.initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final wide = isWide(context);
    final content = IndexedStack(
      index: _index,
      children: [
        DashboardScreen(onNavigate: (index) => setState(() => _index = index)),
        const AccountsScreen(),
        const SessionsScreen(),
        const SettingsScreen(),
      ],
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.only(top: AppTokens.space4, bottom: AppTokens.space5),
                child: const _BrandMark(),
              ),
              destinations: [
                for (final destination in _destinations)
                  NavigationRailDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: Text(destination.label),
                  ),
              ],
            ),
            VerticalDivider(width: 1, color: palette.outline),
            Expanded(child: SafeArea(child: content)),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppTokens.space4,
        title: Row(
          children: [
            const _BrandMark(size: 26),
            const SizedBox(width: AppTokens.space3),
            Text(_destinations[_index].label, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '添加账号',
            onPressed: () => AccountActions.showAddAccountSheet(context),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: AppTokens.space1),
        ],
      ),
      body: SafeArea(child: content),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 品牌标识：渐变圆角方块 + 勾选符号。
class _BrandMark extends StatelessWidget {
  const _BrandMark({this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: palette.accentGradient,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(
        Icons.check_rounded,
        size: size * 0.58,
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF0A0E1A)
            : Colors.white,
      ),
    );
  }
}
