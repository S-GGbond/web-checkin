import 'account.dart';

enum LoginStatus { waiting, exchanging, success, failed }

/// 一次平台授权登录会话。对象由服务持有并原地更新，UI 读同一实例。
class LoginSession {
  LoginSession({
    required this.id,
    required this.provider,
    required this.authUrl,
    this.label = '',
    this.expiresAt,
  });
  final String id;
  final PlatformKind provider;
  final String label;
  final DateTime? expiresAt;

  /// 平台授权页地址；Trae 需要先起本地回调服务，绑定端口后才能生成完整地址。
  String authUrl;

  LoginStatus status = LoginStatus.waiting;
  String message = '等待浏览器授权';
  int? accountId;
  String? accountName;

  bool get isTerminal => status == LoginStatus.success || status == LoginStatus.failed;
}
