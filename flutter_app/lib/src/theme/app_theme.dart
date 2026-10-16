import 'package:flutter/material.dart';

/// 设计令牌：整套 Flutter 界面自成一套视觉语言，不沿用 Web 端配色与布局。
///
/// 方向：深色优先的「极光」主题，深海军蓝背景 + 靛蓝→青色渐变强调，
/// 大圆角卡片、细描边、克制的阴影；亮色主题为同一套令牌的映射。
class AppTokens {
  const AppTokens._();

  // 间距刻度（4 的倍数）
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 24;
  static const double space6 = 32;
  static const double space7 = 48;

  // 圆角
  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 24;
  static const double radiusPill = 999;

  // 布局断点
  static const double wideBreakpoint = 900;
  static const double mediumBreakpoint = 640;
}

/// 语义化颜色。深浅两套主题共用同一组语义名。
class AppPalette {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.accentAlt,
    required this.success,
    required this.warning,
    required this.danger,
    required this.traeColor,
    required this.workbuddyColor,
  });

  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;
  final Color accent;
  final Color accentAlt;
  final Color success;
  final Color warning;
  final Color danger;
  final Color traeColor;
  final Color workbuddyColor;

  LinearGradient get accentGradient => LinearGradient(
        colors: [accent, accentAlt],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  static const dark = AppPalette(
    background: Color(0xFF0A0E1A),
    surface: Color(0xFF131A2E),
    surfaceElevated: Color(0xFF1B2440),
    outline: Color(0xFF2A3555),
    textPrimary: Color(0xFFF2F5FF),
    textSecondary: Color(0xFF98A4C8),
    accent: Color(0xFF6C8CFF),
    accentAlt: Color(0xFF35D6C8),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    danger: Color(0xFFF87171),
    traeColor: Color(0xFF7C6CFF),
    workbuddyColor: Color(0xFF2FA8FF),
  );

  static const light = AppPalette(
    background: Color(0xFFF4F6FC),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFEDF0FA),
    outline: Color(0xFFDCE1F0),
    textPrimary: Color(0xFF151A2C),
    textSecondary: Color(0xFF5A6485),
    accent: Color(0xFF4B63E8),
    accentAlt: Color(0xFF12A594),
    success: Color(0xFF11996B),
    warning: Color(0xFFB47800),
    danger: Color(0xFFD64545),
    traeColor: Color(0xFF5B4BE0),
    workbuddyColor: Color(0xFF1F86D6),
  );
}

/// 通过 [AppTokensScope] 让任意组件按当前主题取到语义色。
class AppTokensScope extends InheritedWidget {
  const AppTokensScope({super.key, required this.palette, required super.child});

  final AppPalette palette;

  static AppPalette of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppTokensScope>();
    return scope?.palette ?? AppPalette.dark;
  }

  @override
  bool updateShouldNotify(AppTokensScope oldWidget) => oldWidget.palette != palette;
}

class AppTheme {
  const AppTheme._();

  static ThemeData dark() => _build(AppPalette.dark, Brightness.dark);
  static ThemeData light() => _build(AppPalette.light, Brightness.light);

  static ThemeData _build(AppPalette palette, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.accent,
      brightness: brightness,
    ).copyWith(
      surface: palette.surface,
      primary: palette.accent,
      secondary: palette.accentAlt,
      error: palette.danger,
      outline: palette.outline,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      fontFamily: null,
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme, palette),
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
          side: BorderSide(color: palette.outline),
        ),
      ),
      dividerTheme: DividerThemeData(color: palette.outline, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: palette.textPrimary,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: brightness == Brightness.dark ? const Color(0xFF0A0E1A) : Colors.white,
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space4,
            vertical: AppTokens.space3,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTokens.radiusSm)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: palette.outline),
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space4,
            vertical: AppTokens.space3,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTokens.radiusSm)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: palette.accent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceElevated,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space4,
          vertical: AppTokens.space3,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          borderSide: BorderSide(color: palette.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          borderSide: BorderSide(color: palette.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          borderSide: BorderSide(color: palette.accent, width: 1.5),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? palette.accent : palette.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent.withValues(alpha: 0.35)
              : palette.surfaceElevated,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: palette.accent.withValues(alpha: 0.16),
        selectedIconTheme: IconThemeData(color: palette.accent),
        unselectedIconTheme: IconThemeData(color: palette.textSecondary),
        selectedLabelTextStyle: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: TextStyle(color: palette.textSecondary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.accent.withValues(alpha: 0.16),
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
            color: states.contains(WidgetState.selected) ? palette.textPrimary : palette.textSecondary,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: palette.surfaceElevated,
        contentTextStyle: TextStyle(color: palette.textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTokens.radiusSm)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          side: BorderSide(color: palette.outline),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        ),
      ),
    );
  }

  static TextTheme _textTheme(TextTheme base, AppPalette palette) {
    return base
        .apply(bodyColor: palette.textPrimary, displayColor: palette.textPrimary)
        .copyWith(
          headlineMedium: base.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
          headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
          titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          bodyMedium: base.bodyMedium?.copyWith(color: palette.textSecondary, height: 1.4),
        );
  }
}
