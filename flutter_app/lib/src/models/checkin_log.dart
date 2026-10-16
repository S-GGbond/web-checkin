import '../models/account.dart';

/// 一条执行日志。
class CheckinLog {
  const CheckinLog({
    required this.id,
    required this.accountId,
    required this.provider,
    required this.action,
    required this.ok,
    required this.message,
    required this.createdAt,
    this.displayName,
    this.label,
    this.code,
  });

  final int id;
  final int accountId;
  final PlatformKind provider;
  final String action;
  final bool ok;
  final String message;
  final int createdAt;
  final String? displayName;
  final String? label;
  final int? code;

  String get accountTitle {
    if (displayName != null && displayName!.isNotEmpty) return displayName!;
    if (label != null && label!.isNotEmpty) return label!;
    return '账号 #$accountId';
  }

  factory CheckinLog.fromRow(Map<String, Object?> row) {
    return CheckinLog(
      id: row['id'] as int,
      accountId: row['account_id'] as int,
      provider: PlatformKind.fromId((row['provider'] as String?) ?? 'workbuddy'),
      action: (row['action'] as String?) ?? '',
      ok: (row['ok'] as int? ?? 0) == 1,
      message: (row['message'] as String?) ?? '',
      createdAt: (row['created_at'] as int?) ?? 0,
      displayName: row['display_name'] as String?,
      label: row['label'] as String?,
      code: row['code'] as int?,
    );
  }
}
