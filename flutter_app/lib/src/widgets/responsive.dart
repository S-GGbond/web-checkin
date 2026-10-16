import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 按可用宽度自适应列数的卡片网格。
class AdaptiveCardGrid extends StatelessWidget {
  const AdaptiveCardGrid({
    super.key,
    required this.children,
    this.minItemWidth = 320,
    this.maxColumns = 3,
    this.spacing = AppTokens.space4,
  });

  final List<Widget> children;
  final double minItemWidth;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        var columns = ((width + spacing) / (minItemWidth + spacing)).floor();
        columns = columns.clamp(1, maxColumns);
        final itemWidth = (width - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}

/// 只在一行内排布、窄屏时允许换行的按钮组。
class WrapActions extends StatelessWidget {
  const WrapActions({super.key, required this.children, this.alignment = WrapAlignment.end});

  final List<Widget> children;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppTokens.space2,
      runSpacing: AppTokens.space2,
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= AppTokens.wideBreakpoint;
bool isMedium(BuildContext context) => MediaQuery.sizeOf(context).width >= AppTokens.mediumBreakpoint;
