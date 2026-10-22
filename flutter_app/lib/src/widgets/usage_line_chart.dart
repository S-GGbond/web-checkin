import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 极简折线图：日消耗趋势（带面积填充、网格与首/中/末日期标注）。
class UsageLineChart extends StatelessWidget {
  const UsageLineChart({
    super.key,
    required this.values,
    required this.labels,
    this.height = 168,
  });

  final List<double> values;

  /// 与 [values] 等长，例如 MM-dd；为空则按索引显示。
  final List<String> labels;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _LineChartPainter(
          values: values,
          labels: labels,
          palette: palette,
        ),
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.values,
    required this.labels,
    required this.palette,
  });

  final List<double> values;
  final List<String> labels;
  final AppPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width < 40 || size.height < 40) return;

    const left = 42.0;
    const right = 8.0;
    const top = 10.0;
    const bottom = 22.0;
    final width = size.width - left - right;
    final height = size.height - top - bottom;
    final maxValue = values.reduce(math.max);
    final maxY = maxValue <= 0 ? 1.0 : maxValue;

    final gridPaint = Paint()
      ..color = palette.outline.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final labelStyle = TextStyle(color: palette.textSecondary, fontSize: 10);

    // 横向网格 + 左侧刻度
    for (var i = 0; i <= 3; i++) {
      final y = top + height * i / 3;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), gridPaint);
      final value = maxY * (3 - i) / 3;
      _text(
        canvas,
        _short(value),
        Offset(left - 6, y),
        labelStyle,
        alignRight: true,
        centerVertically: true,
      );
    }

    Offset pointAt(int index) {
      final dx = values.length == 1 ? width / 2 : width * index / (values.length - 1);
      final dy = height * (1 - values[index] / maxY);
      return Offset(left + dx, top + dy);
    }

    final points = [for (var i = 0; i < values.length; i++) pointAt(i)];

    // 面积
    final fillPath = Path()..moveTo(points.first.dx, top + height);
    for (final point in points) {
      fillPath.lineTo(point.dx, point.dy);
    }
    fillPath
      ..lineTo(points.last.dx, top + height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.accent.withValues(alpha: 0.28),
            palette.accent.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(left, top, width, height)),
    );

    // 折线
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      linePath.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 点（点太多时省略）
    if (values.length <= 20) {
      final dotPaint = Paint()..color = palette.accent;
      final haloPaint = Paint()..color = palette.surface;
      for (final point in points) {
        canvas.drawCircle(point, 4.2, haloPaint);
        canvas.drawCircle(point, 2.6, dotPaint);
      }
    }

    // 日期：首 / 中 / 末
    if (labels.length == values.length && labels.isNotEmpty) {
      final indices = values.length == 1
          ? [0]
          : {0, values.length ~/ 2, values.length - 1}.toList()..sort();
      for (final index in indices) {
        final point = points[index];
        final align = index == 0
            ? _Align.start
            : (index == values.length - 1 ? _Align.end : _Align.center);
        final text = labels[index];
        final painter = _layout(text, labelStyle);
        final dx = switch (align) {
          _Align.start => point.dx,
          _Align.center => point.dx - painter.width / 2,
          _Align.end => point.dx - painter.width,
        };
        painter.paint(canvas, Offset(dx, size.height - bottom + 6));
      }
    }
  }

  String _short(double value) {
    if (value >= 100) return value.toStringAsFixed(0);
    if (value >= 10) return value.toStringAsFixed(0);
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }

  TextPainter _layout(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter;
  }

  void _text(
    Canvas canvas,
    String text,
    Offset anchor,
    TextStyle style, {
    bool alignRight = false,
    bool centerVertically = false,
  }) {
    final painter = _layout(text, style);
    painter.paint(
      canvas,
      Offset(
        alignRight ? anchor.dx - painter.width : anchor.dx,
        centerVertically ? anchor.dy - painter.height / 2 : anchor.dy,
      ),
    );
  }

  @override
  bool shouldRepaint(_LineChartPainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.labels != labels ||
        oldDelegate.palette != palette;
  }
}

enum _Align { start, center, end }
