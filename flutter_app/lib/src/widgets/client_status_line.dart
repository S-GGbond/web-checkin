import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// 平台分组标题下的客户端状态行。
///
/// 只显示「客户端当前登录的是谁」并提示点击卡片切换；
/// 切换动作本身落在账号卡片上（选中卡片带绿色边框）。
class ClientStatusLine extends StatelessWidget {
  const ClientStatusLine({super.key, required this.provider});

  final PlatformKind provider;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    final info = state.desktopClient(provider);

    final phase = state.desktopPhase(provider);
    if (phase != null) {
      return Row(
        children: [
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: AppTokens.space2),
          Expanded(
            child: Text(
              phase,
              style: TextStyle(color: palette.accent, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    if (info != null && info.authFiles.isEmpty) {
      return Row(
        children: [
          Icon(Icons.link_off_rounded, size: 14, color: palette.textSecondary),
          const SizedBox(width: AppTokens.space1),
          Expanded(
            child: Text(
              '未检测到 ${provider.label} 客户端登录态，启动客户端并登录后可在这里切换',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => state.refreshDesktopClients(refreshExecutable: true),
            child: const Text('重新探测'),
          ),
        ],
      );
    }

    final activeId = info?.activeExternalId;
    Account? activeAccount;
    if (activeId != null) {
      for (final account in state.accounts) {
        if (account.provider == provider && account.externalId == activeId) {
          activeAccount = account;
          break;
        }
      }
    }
    final canSwitch = info?.canSwitch ?? false;

    return Wrap(
      spacing: AppTokens.space1,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(Icons.desktop_windows_rounded, size: 13, color: palette.textSecondary),
        Text(
          info == null
              ? '正在检测客户端…'
              : activeId == null
                  ? '客户端未登录'
                  : '客户端当前：${activeAccount?.title ?? _short(activeId)}',
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
        if (info != null && canSwitch)
          Text(
            '· 点击账号卡片即可切换',
            style: TextStyle(color: palette.textSecondary, fontSize: 11),
          ),
        if (info != null && info.authFiles.isNotEmpty && !canSwitch)
          Text(
            '· 未找到客户端主程序，暂不能切换',
            style: TextStyle(color: palette.warning, fontSize: 11),
          ),
      ],
    );
  }

  static String _short(String id) => id.length <= 12 ? id : '${id.substring(0, 12)}…';
}
