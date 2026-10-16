import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/login_session.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'app_widgets.dart';

/// 平台授权登录对话框：展示授权进度、授权链接与重开入口。
class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.session});

  final LoginSession session;

  static Future<void> show(BuildContext context, LoginSession session) {
    return showDialog<void>(
      context: context,
      // 关闭对话框只是停止关注，登录流程仍在后台继续，因此允许点击遮罩、
      // 按 ESC / 返回键关闭。
      barrierDismissible: true,
      builder: (_) => LoginDialog(session: session),
    );
  }

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  late final AppState _state;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>()..addListener(_onChange);
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (widget.session.isTerminal && !_handled) {
      _handled = true;
      final session = widget.session;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pop();
        showAppSnackBar(
          context,
          session.status == LoginStatus.success
              ? '${session.accountName ?? session.provider.label} 登录成功'
              : '登录失败：${session.message}',
          error: session.status == LoginStatus.failed,
        );
        _state.dismissLogin(session);
      });
    }
  }

  @override
  void dispose() {
    _state.removeListener(_onChange);
    super.dispose();
  }

  /// 关闭对话框：登录流程不中断，成功后账号会自动出现。
  void _close() {
    final palette = AppTokensScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.schedule_rounded, size: 18, color: palette.accentAlt),
              const SizedBox(width: AppTokens.space3),
              const Expanded(child: Text('登录在后台继续，成功后会自动添加账号')),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final session = widget.session;
    final waiting = !session.isTerminal;
    final isTrae = session.provider == PlatformKind.trae;
    final color = isTrae ? palette.traeColor : palette.workbuddyColor;
    final icon = isTrae ? Icons.bolt_rounded : Icons.rocket_launch_rounded;

    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(AppTokens.space2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: AppTokens.space3),
          Expanded(child: Text('登录 ${session.provider.label}')),
          IconButton(
            tooltip: '关闭（登录继续在后台进行）',
            visualDensity: VisualDensity.compact,
            onPressed: _close,
            icon: Icon(Icons.close_rounded, size: 20, color: palette.textSecondary),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (waiting)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    session.status == LoginStatus.success ? Icons.check_circle_rounded : Icons.error_rounded,
                    size: 18,
                    color: session.status == LoginStatus.success ? palette.success : palette.danger,
                  ),
                const SizedBox(width: AppTokens.space3),
                Expanded(child: Text(session.message)),
              ],
            ),
            const SizedBox(height: AppTokens.space4),
            Text(
              '已在系统浏览器打开授权页面；若未弹出，请点击下方按钮重新打开。',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: AppTokens.space3),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppTokens.space3),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                border: Border.all(color: palette.outline),
              ),
              child: SelectableText(
                session.authUrl,
                maxLines: 3,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: session.authUrl));
            if (context.mounted) showAppSnackBar(context, '授权链接已复制');
          },
          child: const Text('复制链接'),
        ),
        OutlinedButton.icon(
          onPressed: () => _state.reopenLogin(session),
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: const Text('重新打开'),
        ),
        if (waiting)
          TextButton(
            onPressed: _close,
            child: const Text('后台等待'),
          ),
      ],
    );
  }
}
