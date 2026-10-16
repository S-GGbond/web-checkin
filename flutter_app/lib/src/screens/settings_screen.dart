import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../services/background/background_scheduler.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/account_actions.dart';
import '../widgets/app_widgets.dart';
import '../widgets/responsive.dart';

/// 设置：数据位置、维护操作与关于信息。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);

    return ListView(
      padding: const EdgeInsets.all(AppTokens.space5),
      children: [
        SectionTitle(title: '设置', subtitle: '数据位置、维护操作与平台说明'),
        const SizedBox(height: AppTokens.space5),
        _SettingsCard(
          title: '数据与登录态',
          children: [
            Text('账号库位置', style: TextStyle(color: palette.textSecondary, fontSize: 12)),
            const SizedBox(height: AppTokens.space2),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppTokens.space3),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                border: Border.all(color: palette.outline),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      state.db.path,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制路径',
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: state.db.path));
                      if (context.mounted) showAppSnackBar(context, '路径已复制');
                    },
                    icon: Icon(Icons.copy_rounded, size: 16, color: palette.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.space4),
            _InfoLine(
              icon: Icons.lock_outline_rounded,
              text: 'Trae 登录态以 AES-128-CBC + SHA-512 容器加密存放；WorkBuddy 登录态按平台要求明文存放，请勿拷贝该数据库。',
            ),
            _InfoLine(
              icon: Icons.timer_outlined,
              text: '每日定时由操作系统调度，应用关闭后仍会执行；失败最多重试 3 次，'
                  '每次重试间隔 5 分钟。',
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space4),
        _SettingsCard(
          title: '维护',
          children: [
            _ActionRow(
              icon: Icons.sync_rounded,
              title: '刷新全部账号状态',
              subtitle: '重新拉取余额与签到状态',
              trailing: OutlinedButton(
                onPressed: state.refreshing ? null : () => AccountActions.refreshAll(context),
                child: Text(state.refreshing ? '刷新中' : '刷新'),
              ),
            ),
            _ActionRow(
              icon: Icons.done_all_rounded,
              title: '全部账号立即签到',
              subtitle: '对所有启用账号执行一次签到',
              trailing: OutlinedButton(
                onPressed: () => AccountActions.checkinAll(context),
                child: const Text('签到'),
              ),
            ),
            _ActionRow(
              icon: Icons.download_rounded,
              title: '从本机 Trae 客户端导入',
              subtitle: '读取本机 Trae 的登录态，免扫码登录',
              trailing: OutlinedButton(
                onPressed: () async {
                  final error = await state.importTraeFromDesktop();
                  if (!context.mounted) return;
                  showAppSnackBar(context, error ?? '已导入本机 Trae 登录态', error: error != null);
                },
                child: const Text('导入'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space4),
        _BackgroundScheduleCard(state: state),
        const SizedBox(height: AppTokens.space4),
        _SettingsCard(
          title: '关于',
          children: [
            _ActionRow(
              icon: Icons.apps_rounded,
              title: '签到中枢',
              subtitle: 'Flutter 跨端客户端 · 版本 1.0.0',
              trailing: const SizedBox.shrink(),
            ),
            _ActionRow(
              icon: Icons.devices_rounded,
              title: '支持的平台',
              subtitle: PlatformKind.values.map((p) => p.label).join(' · '),
              trailing: const SizedBox.shrink(),
            ),
            _InfoLine(
              icon: Icons.info_outline_rounded,
              text: '本项目与 WorkBuddy、Trae 官方没有隶属关系，请仅管理你本人拥有授权的账号，并遵守各平台服务条款。',
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.children});

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

class _ActionRow extends StatelessWidget {
  const _ActionRow({
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
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.accent),
          const SizedBox(width: AppTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: palette.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.space3),
          trailing,
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

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

/// 系统级后台定时：展示机制、限制与已注册的账号。
class _BackgroundScheduleCard extends StatelessWidget {
  const _BackgroundScheduleCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final BackgroundSchedulerStatus info = state.backgroundStatus;
    final accountsById = {for (final account in state.accounts) account.id: account};

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('系统级后台定时', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (state.backgroundSyncing)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                StatusPill(
                  label: info.available ? '${info.installedCount} 个已注册' : '不可用',
                  color: info.available ? palette.success : palette.textSecondary,
                  icon: info.available ? Icons.verified_rounded : Icons.block_rounded,
                ),
            ],
          ),
          const SizedBox(height: AppTokens.space2),
          Text(
            info.mechanism,
            style: TextStyle(color: palette.accent, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppTokens.space3),
          if (info.note != null)
            _InfoLine(icon: Icons.info_outline_rounded, text: info.note!),
          if (info.lastError != null)
            _InfoLine(icon: Icons.error_outline_rounded, text: '最近一次同步失败：${info.lastError}'),
          if (state.needsExactAlarmPermission)
            _InfoLine(
              icon: Icons.alarm_on_rounded,
              text: '尚未授予「闹钟和提醒」权限：当前只能用非精确闹钟，系统可能推迟执行。'
                  '点右侧按钮去系统设置里开启，回来后会自动重新同步。',
            ),
          const SizedBox(height: AppTokens.space3),
          if (info.installed.isEmpty)
            Text(
              '尚未注册系统任务。开启某个账号的「定时」后会自动注册在这里。',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            )
          else
            for (final entry in info.installed.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTokens.space2),
                child: Row(
                  children: [
                    Icon(Icons.event_available_rounded, size: 15, color: palette.success),
                    const SizedBox(width: AppTokens.space2),
                    Expanded(
                      child: Text(
                        accountsById[entry.key]?.title ?? '账号 #${entry.key}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '每日 ${entry.value}',
                      style: TextStyle(color: palette.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: AppTokens.space3),
          Text(
            '可执行文件：${info.executablePath}',
            style: TextStyle(color: palette.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: AppTokens.space4),
          WrapActions(
            alignment: WrapAlignment.start,
            children: [
              if (state.needsExactAlarmPermission)
                FilledButton.icon(
                  onPressed: () => state.openExactAlarmSettings(),
                  icon: const Icon(Icons.alarm_add_rounded, size: 18),
                  label: const Text('去开启精确闹钟'),
                ),
              OutlinedButton.icon(
                onPressed: state.backgroundSyncing
                    ? null
                    : () async {
                        final error = await state.syncBackgroundSchedule();
                        if (!context.mounted) return;
                        showAppSnackBar(context, error ?? '已同步到系统计划任务', error: error != null);
                      },
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: const Text('立即同步'),
              ),
              OutlinedButton.icon(
                onPressed: info.installed.isEmpty
                    ? null
                    : () async {
                        final error = await state.uninstallBackgroundSchedule();
                        if (!context.mounted) return;
                        showAppSnackBar(context, error ?? '已从系统移除全部定时任务', error: error != null);
                      },
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('从系统移除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
