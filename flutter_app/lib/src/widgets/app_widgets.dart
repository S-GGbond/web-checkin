import 'dart:math';

import 'package:flutter/material.dart';

import '../models/account.dart';
import '../theme/app_theme.dart';

/// 带渐变描边的玻璃质感容器。
class GradientSurface extends StatelessWidget {
  const GradientSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppTokens.space5),
    this.gradient,
    this.borderRadius = AppTokens.radiusLg,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Gradient? gradient;
  final double borderRadius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final radius = BorderRadius.circular(borderRadius);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: gradient ?? palette.accentGradient,
        borderRadius: radius,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 普通表面卡片，带细描边。
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppTokens.space4),
    this.onTap,
    this.highlight = false,
    this.borderColor,
    this.borderWidth = 1,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool highlight;

  /// 自定义描边颜色，默认使用主题的分隔线色。
  final Color? borderColor;

  /// 描边宽度；选中态可以用更粗的边框强调。
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Material(
      color: highlight ? palette.surfaceElevated : palette.surface,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(color: borderColor ?? palette.outline, width: borderWidth),
          ),
          child: child,
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        if (subtitle != null) ...[
          const SizedBox(height: AppTokens.space1),
          Text(
            subtitle!,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
    final extra = trailing;
    if (extra == null) return text;

    // 窄屏（手机）把操作按钮挪到标题下面，否则标题会被挤成一两个字一行。
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              text,
              const SizedBox(height: AppTokens.space3),
              Align(alignment: Alignment.centerLeft, child: extra),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [Expanded(child: text), extra],
        );
      },
    );
  }
}

/// 平台图标：账号卡片、分组标题、登录对话框共用。
IconData providerIcon(PlatformKind provider) => switch (provider) {
      PlatformKind.workbuddy => Icons.rocket_launch_rounded,
      PlatformKind.trae => Icons.bolt_rounded,
      PlatformKind.qoder => Icons.terminal_rounded,
    };

/// 指标小卡。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.accent,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final color = accent ?? palette.accent;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(AppTokens.space2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(height: AppTokens.space4),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 26),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppTokens.space1),
          Text(label, style: TextStyle(color: palette.textSecondary, fontSize: 13)),
        ],
      ),
    );
  }
}

class ProviderChip extends StatelessWidget {
  const ProviderChip({super.key, required this.provider, this.dense = false});

  final PlatformKind provider;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final color = palette.colorOf(provider);
    final icon = providerIcon(provider);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? AppTokens.space2 : AppTokens.space3,
        vertical: dense ? 2 : AppTokens.space1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 12 : 14, color: color),
          const SizedBox(width: AppTokens.space1),
          Text(
            provider.label,
            style: TextStyle(
              color: color,
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态胶囊：已签到 / 未签到 / 已停用 / 失败。
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.space3, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: AppTokens.space1),
          ],
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 用量进度环。
class UsageRing extends StatelessWidget {
  const UsageRing({
    super.key,
    required this.progress,
    required this.color,
    this.size = 56,
    this.center,
  });

  final double progress;
  final Color color;
  final double size;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress.clamp(0, 1).toDouble()),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => CustomPaint(
                painter: _RingPainter(
                  progress: value,
                  color: color,
                  background: palette.outline,
                ),
              ),
            ),
          ),
          ?center,
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.background});

  final double progress;
  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.12;
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = background;
    canvas.drawArc(rect, -pi / 2, pi * 2, false, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = color;
    canvas.drawArc(rect, -pi / 2, pi * 2 * progress, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color || old.background != background;
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(AppTokens.space4),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: palette.textSecondary),
            ),
            const SizedBox(height: AppTokens.space4),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: AppTokens.space2),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSecondary, fontSize: 13),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppTokens.space5),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 统一的提示条。
void showAppSnackBar(BuildContext context, String message, {bool error = false}) {
  final palette = AppTokensScope.of(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 18,
              color: error ? palette.danger : palette.success,
            ),
            const SizedBox(width: AppTokens.space3),
            Expanded(child: Text(message)),
          ],
        ),
        duration: const Duration(seconds: 4),
      ),
    );
}
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppTokens.space4),
          ...children,
        ],
      ),
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space3),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(color: palette.textSecondary, fontSize: 12),
              ),
            ],
          );
          // 窄屏把按钮放到说明下面，避免标题被挤成一两个字一行。
          final compact = constraints.maxWidth < 480;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: palette.accent),
              const SizedBox(width: AppTokens.space3),
              Expanded(
                child: compact
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          text,
                          const SizedBox(height: AppTokens.space2),
                          Align(alignment: Alignment.centerRight, child: trailing),
                        ],
                      )
                    : text,
              ),
              if (!compact) ...[
                const SizedBox(width: AppTokens.space3),
                trailing,
              ],
            ],
          );
        },
      ),
    );
  }
}

class SettingsNote extends StatelessWidget {
  const SettingsNote({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 15, color: palette.textSecondary),
          ),
          const SizedBox(width: AppTokens.space2),
          Expanded(
            child: Text(text, style: TextStyle(color: palette.textSecondary, fontSize: 12, height: 1.5)),
          ),
        ],
      ),
    );
  }
}

