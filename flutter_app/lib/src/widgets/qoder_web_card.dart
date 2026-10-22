import 'package:flutter/material.dart';

import '../models/account.dart';
import '../services/qoder/qoder_browser_cookie.dart';
import '../services/qoder/qoder_web_usage.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'app_widgets.dart';

/// Qoder 网页用量明细：登录态来源、归属账号与配置入口。
///
/// 逐笔明细（模型 / 会话 / 是否计费）只有 qoder.cn 网页接口有，需要网页登录态；
/// 桌面端可直接复用本机浏览器的 Cookie，移动端只能手动填写。
class QoderWebCard extends StatefulWidget {
  const QoderWebCard({required this.state, this.usage, super.key});

  final AppState state;

  /// 测试注入：默认用账号库新建一个实例。
  final QoderWebUsage? usage;

  @override
  State<QoderWebCard> createState() => _QoderWebCardState();
}

class _QoderWebCardState extends State<QoderWebCard> {
  /// 上次探测结果：重新进设置页先显示它，2 分钟内不重复请求。
  static ({QoderWebState state, DateTime at})? _statusCache;
  static const _cacheTtl = Duration(minutes: 2);

  QoderWebUsage? _web;
  QoderWebState? _status;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_web != null) return;
    _web = widget.usage ?? QoderWebUsage(widget.state.db);
    _refresh();
  }

  Future<void> _refresh({bool force = false}) async {
    final web = _web;
    if (web == null) return;
    // 测试注入了 usage 时不走缓存。
    final cached = widget.usage == null ? _statusCache : null;
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.at) < _cacheTtl) {
      if (mounted) setState(() => _status = cached.state);
      return;
    }
    setState(() => _busy = true);
    try {
      final status = await web.probe();
      if (widget.usage == null) {
        _statusCache = (state: status, at: DateTime.now());
      }
      if (mounted) setState(() => _status = status);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 抓取浏览器登录态，并按 user_id 绑定到对应账号。
  Future<void> _capture() async {
    final web = _web;
    if (web == null) return;
    setState(() => _busy = true);
    try {
      final bound = await web.captureAll();
      final status = await web.probe();
      _statusCache = (state: status, at: DateTime.now());
      if (!mounted) return;
      setState(() => _status = status);
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        bound > 0
            ? '已绑定 $bound 个账号的网页登录态'
            : '没有匹配到可绑定的账号，请先在浏览器打开 qoder.cn 完成一次登录',
      );
    } on QoderCookieException catch (error) {
      if (mounted) showAppSnackBar(context, error.message);
    } catch (error) {
      if (mounted) showAppSnackBar(context, '抓取失败：${error.toString()}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusLine(
    QoderWebState? status,
    String owner,
    int total,
    int bound,
  ) {
    if (bound > 0) {
      return '登录态：已绑定 $bound / $total 个账号（登录时自动抓取）';
    }
    final source = status?.source ?? '未配置';
    return '登录态：$source${owner.isEmpty ? '' : '（归属 $owner）'}';
  }

  Future<void> _saveCookie() async {
    final web = _web;
    if (web == null) return;
    final current = await web.manualCookie();
    if (!mounted) return;
    final input = await showDialog<String>(
      context: context,
      builder: (_) => _CookieDialog(initial: current),
    );
    if (input == null) return;
    await web.saveManualCookie(input);
    await _refresh(force: true);
    if (!mounted) return;
    showAppSnackBar(context, '已保存手动 Cookie');
  }

  Future<void> _clear() async {
    final web = _web;
    if (web == null) return;
    await web.clearManualCookie();
    await _refresh(force: true);
    if (!mounted) return;
    showAppSnackBar(context, '已清除手动 Cookie');
  }

  String _ownerOf(String uid) {
    if (uid.isEmpty) return '';
    for (final account in widget.state.accounts) {
      if (account.provider == PlatformKind.qoder && account.externalId == uid) {
        return account.title;
      }
    }
    return uid;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final status = _status;
    final owner = _ownerOf(status?.userId ?? '');
    final total = widget.state.accounts
        .where((account) => account.provider == PlatformKind.qoder)
        .length;
    final bound = status?.boundAccounts ?? 0;
    final manual = status != null && !status.fromBrowser && status.available;

    return SettingsCard(
      title: 'Qoder 用量明细',
      children: [
        SettingsNote(
          icon: Icons.travel_explore_rounded,
          text: '用量页的 Qoder 明细来自 qoder.cn 网页接口（逐笔记录模型、会话与是否计费）。'
              '登录 Qoder 账号时，程序会顺手把浏览器里刚建立的网页登录态绑到该账号上；'
              '之后查明细直接用它，不需要再单独登录网页。',
        ),
        const SizedBox(height: AppTokens.space2),
        Row(
          children: [
            Icon(
              status?.available == true
                  ? Icons.link_rounded
                  : Icons.link_off_rounded,
              size: 15,
              color: status?.available == true
                  ? palette.success
                  : palette.textSecondary,
            ),
            const SizedBox(width: AppTokens.space2),
            Expanded(
              child: Text(
                _busy && status == null
                    ? '正在检测登录态…'
                    : _statusLine(status, owner, total, bound),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        if (total > 0 && bound < total) ...[
          const SizedBox(height: AppTokens.space2),
          Text(
            '还有 ${total - bound} 个账号没有网页登录态：对这些账号重新登录一次即可自动抓取。',
            style: TextStyle(
              fontSize: 11,
              color: palette.textSecondary,
              height: 1.5,
            ),
          ),
        ],
        if (status != null && status.error.isNotEmpty) ...[
          const SizedBox(height: AppTokens.space2),
          Text(
            status.error,
            style: TextStyle(
              fontSize: 11,
              color: palette.danger,
              height: 1.5,
            ),
          ),
        ],
        const SizedBox(height: AppTokens.space4),
        if (_web?.browserSupported ?? false)
          SettingsRow(
            icon: Icons.travel_explore_rounded,
            title: '立即抓取登录态',
            subtitle: '从 Chrome / Chromium / Edge 的 Cookies 里按账号匹配并绑定',
            trailing: OutlinedButton(
              onPressed: _busy ? null : _capture,
              child: const Text('抓取'),
            ),
          ),
        SettingsRow(
          icon: Icons.key_rounded,
          title: '手动填写 Cookie',
          subtitle: '在浏览器开发者工具里复制 qoder.cn 的 Cookie 请求头',
          trailing: OutlinedButton(
            onPressed: _busy ? null : _saveCookie,
            child: const Text('填写'),
          ),
        ),
        if (manual)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _clear,
              child: const Text('清除手动 Cookie'),
            ),
          ),
      ],
    );
  }
}

/// 手动粘贴 Cookie 的输入框。
class _CookieDialog extends StatefulWidget {
  const _CookieDialog({required this.initial});

  final String initial;

  @override
  State<_CookieDialog> createState() => _CookieDialogState();
}

class _CookieDialogState extends State<_CookieDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (!text.contains('qoder_session_cookie')) {
      setState(() => _error = 'Cookie 里没有 qoder_session_cookie，请确认复制的是 qoder.cn 的请求头');
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return AlertDialog(
      title: const Text('填写 qoder.cn Cookie'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'qoder_session_cookie=...; 其他字段可一并粘贴',
                isDense: true,
              ),
            ),
            const SizedBox(height: AppTokens.space2),
            Text(
              _error ?? '在浏览器打开 qoder.cn → 开发者工具 → Network，复制任意请求的 Cookie 请求头。',
              style: TextStyle(
                fontSize: 11,
                color: _error == null ? palette.textSecondary : palette.danger,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
