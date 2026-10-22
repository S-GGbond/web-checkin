import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/usage_record.dart';
import '../services/qoder/qoder_service.dart';
import '../services/trae/trae_service.dart';
import '../services/workbuddy/workbuddy_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/responsive.dart';
import '../widgets/usage_line_chart.dart';

/// 用量：总消耗、每日趋势、平台/模型分布与会话明细。
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, this.loader});

  /// 仅测试使用：注入用量数据，避免真实网络请求。
  final Future<UsageLoadResult> Function(int days)? loader;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  static const _ranges = [7, 30, 90];

  int _days = 7;
  PlatformKind? _filter;
  final Set<int> _selectedAccounts = {};
  bool _loading = true;
  Object? _error;
  UsageLoadResult _result = UsageLoadResult.empty;

  /// 页面级缓存：再次进入先显示上次结果，短时间内不重复请求。
  static ({int days, DateTime at, UsageLoadResult result})? _cache;
  static const _cacheTtl = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    // 测试注入 loader 时不走缓存，避免上一个用例的数据串过来。
    final cached = widget.loader == null ? _cache : null;
    final sameRange = cached != null && cached.days == _days;
    if (!force &&
        sameRange &&
        DateTime.now().difference(cached.at) < _cacheTtl) {
      setState(() {
        _result = cached.result;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      // 有同区间的旧数据就直接用，后台刷新，不再整页转圈。
      if (sameRange) _result = cached.result;
      _loading = !sameRange;
      _error = null;
    });
    try {
      final result = await (widget.loader ?? _defaultLoader)(_days);
      if (!mounted) return;
      if (widget.loader == null) {
        _cache = (days: _days, at: DateTime.now(), result: result);
      }
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// 逐个账号拉取用量：WorkBuddy 走逐笔请求，Trae 走按会话聚合。
  Future<UsageLoadResult> _defaultLoader(int days) async {
    final db = context.read<AppState>().db;
    final rows = await db.listAccountRows();
    final trae = TraeService(db);
    final workbuddy = WorkBuddyService(db);
    final qoder = QoderService(db);
    final entries = <UsageEntry>[];
    final errors = <({String account, String message})>[];
    final accounts = <UsageAccountRef>[];
    var total = 0;

    Future<void> loadOne(Map<String, Object?> row) async {
      final account = Account.fromRow(row);
      if (!account.enabled) return;
      accounts.add(
        UsageAccountRef(
          id: account.id,
          name: account.title,
          provider: account.provider,
        ),
      );
      try {
        final result = switch (account.provider) {
          PlatformKind.trae => await trae.queryUsage(row, days: days),
          PlatformKind.workbuddy => await workbuddy.queryUsage(row, days: days),
          PlatformKind.qoder => await qoder.queryUsage(row, days: days),
        };
        entries.addAll(result.entries);
        total += result.total;
      } catch (error) {
        errors.add((account: account.title, message: '$error'));
      }
    }

    await Future.wait(rows.map(loadOne));
    entries.sort((a, b) => b.time.compareTo(a.time));
    accounts.sort((a, b) => a.name.compareTo(b.name));
    return UsageLoadResult(
      entries: entries,
      errors: errors,
      total: total,
      accounts: accounts,
    );
  }

  List<UsageEntry> get _visible {
    final filter = _filter;
    final accounts = _selectedAccounts;
    return _result.entries.where((entry) {
      if (filter != null && entry.provider != filter) return false;
      if (accounts.isNotEmpty && !accounts.contains(entry.accountId)) {
        return false;
      }
      return true;
    }).toList();
  }

  static String _shortName(String name) {
    final text = name.trim();
    if (text.length <= 12) return text;
    return '@@{text.substring(0, 11)}…';
  }

  static String _dayKey(DateTime time) =>
      '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';

  static String _fmt(double value) {
    if (value >= 1000) return value.toStringAsFixed(0);
    if (value >= 10) return value.toStringAsFixed(1);
    final text = value.toStringAsFixed(2);
    return text.endsWith('0') ? text.substring(0, text.length - 1) : text;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final visible = _visible;
    final credits = visible.fold<double>(0, (sum, entry) => sum + entry.credits);
    final days = _chartData(visible);
    final grouped = _groupByDay(visible);
    final providers = <PlatformKind, double>{};
    for (final entry in visible) {
      providers[entry.provider] = (providers[entry.provider] ?? 0) + entry.credits;
    }
    final models = <String, double>{};
    for (final entry in visible) {
      if (entry.model.isEmpty) continue;
      models[entry.model] = (models[entry.model] ?? 0) + entry.credits;
    }
    final topModels = models.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.all(AppTokens.space5),
      children: [
        SectionTitle(
          title: '用量',
          subtitle: '最近 $_days 天 · 共 ${visible.length} 条记录',
          trailing: WrapActions(
            alignment: WrapAlignment.end,
            children: [
              for (final range in _ranges)
                ChoiceChip(
                  label: Text('$range 天'),
                  selected: _days == range,
                  onSelected: (_) {
                    if (_days == range) return;
                    setState(() => _days = range);
                    _load();
                  },
                ),
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : () => _load(force: true),
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.space3),
        Wrap(
          spacing: AppTokens.space2,
          runSpacing: AppTokens.space1,
          children: [
            ChoiceChip(
              label: const Text('全部平台'),
              selected: _filter == null,
              onSelected: (_) => setState(() {
                _filter = null;
                _selectedAccounts.clear();
              }),
            ),
            for (final provider in PlatformKind.values)
              ChoiceChip(
                label: Text(provider.label),
                selected: _filter == provider,
                onSelected: (_) => setState(() {
                  _filter = provider;
                  _selectedAccounts.clear();
                }),
              ),
          ],
        ),
        if (_result.accounts.isNotEmpty) ...[
          const SizedBox(height: AppTokens.space2),
          Wrap(
            spacing: AppTokens.space2,
            runSpacing: AppTokens.space1,
            children: [
              FilterChip(
                label: const Text('全部账号'),
                selected: _selectedAccounts.isEmpty,
                onSelected: (_) => setState(_selectedAccounts.clear),
              ),
              for (final account in _result.accounts)
                if (_filter == null || account.provider == _filter)
                  FilterChip(
                    label: Text(_shortName(account.name)),
                    selected: _selectedAccounts.contains(account.id),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _selectedAccounts.add(account.id);
                      } else {
                        _selectedAccounts.remove(account.id);
                      }
                    }),
                  ),
            ],
          ),
        ],
        const SizedBox(height: AppTokens.space4),
        if (_loading && _result.entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppTokens.space6),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          EmptyState(
            icon: Icons.cloud_off_rounded,
            title: '用量加载失败',
            message: '$_error',
            action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          )
        else if (visible.isEmpty)
          EmptyState(
            icon: Icons.insights_rounded,
            title: '还没有用量记录',
            message: _selectedAccounts.isEmpty && _filter == null
                ? '最近 $_days 天没有查到积分消耗；确认账号已登录并且使用过对话。'
                : '当前筛选条件下没有用量记录，换个账号或平台试试。',
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: _Metric(
                  icon: Icons.local_fire_department_rounded,
                  label: '总消耗',
                  value: _fmt(credits),
                  unit: '积分',
                  color: palette.accent,
                ),
              ),
              const SizedBox(width: AppTokens.space2),
              Expanded(
                child: _Metric(
                  icon: Icons.receipt_long_rounded,
                  label: '记录数',
                  value: '${visible.length}',
                  unit: '条',
                  color: palette.traeColor,
                ),
              ),
              const SizedBox(width: AppTokens.space2),
              Expanded(
                child: _Metric(
                  icon: Icons.timeline_rounded,
                  label: '日均',
                  value: _fmt(credits / _days),
                  unit: '积分',
                  color: palette.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.space4),
          SurfaceCard(
            padding: const EdgeInsets.all(AppTokens.space4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('每日消耗', style: Theme.of(context).textTheme.titleSmall),
                    const Spacer(),
                    Text(
                      '峰值 ${_fmt(days.values.isEmpty ? 0 : days.values.reduce(math.max))} 积分',
                      style: TextStyle(color: palette.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.space3),
                UsageLineChart(values: days.values, labels: days.labels),
              ],
            ),
          ),
          if (providers.length > 1) ...[
            const SizedBox(height: AppTokens.space4),
            _ProviderSplit(totals: providers),
          ],
          if (topModels.isNotEmpty) ...[
            const SizedBox(height: AppTokens.space4),
            _TopModels(items: topModels.take(5).toList()),
          ],
          if (_result.errors.isNotEmpty) ...[
            const SizedBox(height: AppTokens.space4),
            _ErrorCard(errors: _result.errors),
          ],
          const SizedBox(height: AppTokens.space5),
          SectionTitle(
            title: '会话明细',
            subtitle: '按天汇总，最多显示最近 300 条',
          ),
          const SizedBox(height: AppTokens.space3),
          ..._buildDayGroups(context, grouped),
        ],
      ],
    );
  }

  ({List<double> values, List<String> labels}) _chartData(List<UsageEntry> entries) {
    final now = DateTime.now();
    final start = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: _days - 1));
    final totals = <String, double>{};
    for (final entry in entries) {
      final key = _dayKey(entry.time);
      totals[key] = (totals[key] ?? 0) + entry.credits;
    }
    final values = <double>[];
    final labels = <String>[];
    for (var i = 0; i < _days; i++) {
      final day = start.add(Duration(days: i));
      values.add(totals[_dayKey(day)] ?? 0);
      labels.add(DateFormat('MM-dd').format(day));
    }
    return (values: values, labels: labels);
  }

  Map<String, List<UsageEntry>> _groupByDay(List<UsageEntry> entries) {
    final grouped = <String, List<UsageEntry>>{};
    for (final entry in entries) {
      grouped.putIfAbsent(_dayKey(entry.time), () => []).add(entry);
    }
    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    return {
      for (final key in keys)
        key: grouped[key]!..sort((a, b) => b.time.compareTo(a.time)),
    };
  }

  List<Widget> _buildDayGroups(
    BuildContext context,
    Map<String, List<UsageEntry>> grouped,
  ) {
    final palette = AppTokensScope.of(context);
    final widgets = <Widget>[];
    var shown = 0;
    for (final entry in grouped.entries) {
      if (shown >= 300) break;
      final rows = entry.value.take(300 - shown).toList();
      shown += rows.length;
      final sum = rows.fold<double>(0, (value, row) => value + row.credits);
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppTokens.space3),
          child: SurfaceCard(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space4,
              AppTokens.space3,
              AppTokens.space4,
              AppTokens.space2,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      entry.key,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    Text(
                      '${_fmt(sum)} 积分',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.space2),
                for (var i = 0; i < rows.length; i++) ...[
                  _UsageTile(entry: rows[i]),
                  if (i != rows.length - 1)
                    Divider(height: 1, color: palette.outline),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return widgets;
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: AppTokens.space2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  unit,
                  style: TextStyle(color: palette.textSecondary, fontSize: 10),
                ),
              ],
            ),
          ),
          Text(
            label,
            style: TextStyle(color: palette.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _ProviderSplit extends StatelessWidget {
  const _ProviderSplit({required this.totals});

  final Map<PlatformKind, double> totals;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final sum = totals.values.fold<double>(0, (a, b) => a + b);
    if (sum <= 0) return const SizedBox.shrink();
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('平台分布', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppTokens.space3),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                for (final entry in totals.entries)
                  Expanded(
                    flex: math.max(1, (entry.value / sum * 1000).round()),
                    child: Container(
                      height: 10,
                      color: palette.colorOf(entry.key),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.space3),
          Wrap(
            spacing: AppTokens.space4,
            runSpacing: AppTokens.space1,
            children: [
              for (final entry in totals.entries)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: entry.key == PlatformKind.trae
                            ? palette.traeColor
                            : palette.workbuddyColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppTokens.space1),
                    Text(
                      '${entry.key.label} ${_UsageScreenState._fmt(entry.value)} 积分',
                      style: TextStyle(color: palette.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopModels extends StatelessWidget {
  const _TopModels({required this.items});

  final List<MapEntry<String, double>> items;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final maxValue = items.isEmpty ? 1.0 : items.first.value;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('模型消耗 Top 5', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppTokens.space3),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTokens.space2),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      item.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Stack(
                        children: [
                          Container(height: 6, color: palette.outline),
                          FractionallySizedBox(
                            widthFactor: (item.value / maxValue).clamp(0.02, 1),
                            child: Container(height: 6, color: palette.accent),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTokens.space2),
                  Text(
                    _UsageScreenState._fmt(item.value),
                    style: TextStyle(color: palette.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.errors});

  final List<({String account, String message})> errors;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 16, color: palette.danger),
              const SizedBox(width: AppTokens.space2),
              Text(
                '${errors.length} 个账号查询失败',
                style: TextStyle(color: palette.danger, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.space2),
          for (final error in errors.take(4))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${error.account}：${error.message}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.textSecondary, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _UsageTile extends StatelessWidget {
  const _UsageTile({required this.entry});

  final UsageEntry entry;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final title = entry.title.trim().replaceAll(RegExp(r'\s+'), ' ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.space2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty ? '（无摘要）' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: AppTokens.space2,
                  children: [
                    Text(
                      entry.model.isEmpty ? '-' : entry.model,
                      style: TextStyle(color: palette.accent, fontSize: 11),
                    ),
                    Text(
                      entry.client.isEmpty ? entry.accountName : entry.client,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.space3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _UsageScreenState._fmt(entry.credits),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              Text(
                DateFormat('HH:mm').format(entry.time),
                style: TextStyle(color: palette.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
