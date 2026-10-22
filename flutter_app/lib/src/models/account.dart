import 'dart:convert';

/// 支持的平台。当前实现 WorkBuddy 与 Trae 两个平台。
enum PlatformKind {
  workbuddy('workbuddy', 'WorkBuddy'),
  trae('trae', 'Trae'),
  qoder('qoder', 'Qoder');

  const PlatformKind(this.id, this.label);

  final String id;
  final String label;

  static PlatformKind fromId(String id) {
    return PlatformKind.values.firstWhere(
      (p) => p.id == id,
      orElse: () => PlatformKind.workbuddy,
    );
  }
}

/// 账号用量/余额摘要。
class UsageSummary {
  const UsageSummary({
    this.creditsTotal,
    this.creditsLeft,
    this.creditsUsed,
    this.unlimited = false,
  });

  final num? creditsTotal;
  final num? creditsLeft;
  final num? creditsUsed;
  final bool unlimited;

  static UsageSummary? fromCredentialStatus(Map<String, dynamic>? status) {
    final usage = status?['usage'];
    if (usage is! Map) return null;
    return UsageSummary(
      creditsTotal: usage['creditsTotal'] as num?,
      creditsLeft: usage['creditsLeft'] as num?,
      creditsUsed: usage['creditsUsed'] as num?,
      unlimited: usage['unlimited'] == true,
    );
  }

  String get leftLabel {
    if (unlimited) return '不限量';
    if (creditsLeft == null) return '—';
    return _trim(creditsLeft!);
  }

  String get totalLabel {
    if (unlimited) return '不限量';
    if (creditsTotal == null) return '—';
    return _trim(creditsTotal!);
  }

  double get progress {
    if (unlimited) return 1;
    final total = creditsTotal;
    final left = creditsLeft;
    if (total == null || left == null || total <= 0) return 0;
    return (left / total).clamp(0, 1).toDouble();
  }

  static String _trim(num value) {
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toStringAsFixed(2);
  }
}

/// 统一账号记录。
class Account {
  Account({
    required this.id,
    required this.provider,
    required this.externalId,
    required this.displayName,
    required this.label,
    required this.endpoint,
    required this.credential,
    required this.enabled,
    required this.scheduleEnabled,
    required this.scheduleTime,
    this.scheduleLastDate,
    this.lastStatus,
    this.lastStatusAt,
    this.lastCheckinAt,
    this.lastCheckinOk,
    this.lastCheckinMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final PlatformKind provider;
  final String externalId;
  final String displayName;
  final String label;
  final String endpoint;
  final String credential;
  final bool enabled;
  final bool scheduleEnabled;
  final String scheduleTime;
  final String? scheduleLastDate;
  final Map<String, dynamic>? lastStatus;
  final int? lastStatusAt;
  final int? lastCheckinAt;
  final bool? lastCheckinOk;
  final String? lastCheckinMessage;
  final int createdAt;
  final int updatedAt;

  String get title => displayName.isNotEmpty ? displayName : (label.isNotEmpty ? label : externalId);

  UsageSummary? get usage => UsageSummary.fromCredentialStatus(lastStatus);

  /// 今日是否已签到（各平台字段不同，逻辑与后端对齐）。
  bool get checkedInToday {
    final status = lastStatus;
    if (status == null) return false;
    final locallyClaimed = _sameDay(lastCheckinAt) && lastCheckinOk == true;
    switch (provider) {
      case PlatformKind.workbuddy:
        return status['today_checked_in'] == true || locallyClaimed;
      case PlatformKind.trae:
      case PlatformKind.qoder:
        return status['checked_in'] == true || locallyClaimed;
    }
  }

  /// 签到活动是否处于开启状态（Trae 无此字段时默认视为开启）。
  bool get activityActive {
    final status = lastStatus;
    if (status == null) return true;
    final active = status['active'];
    return active is bool ? active : true;
  }

  static bool _sameDay(int? timestamp) {
    if (timestamp == null) return false;
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  Account copyWith({
    String? displayName,
    String? credential,
    bool? enabled,
    bool? scheduleEnabled,
    String? scheduleTime,
    String? scheduleLastDate,
    Map<String, dynamic>? lastStatus,
    int? lastStatusAt,
    int? lastCheckinAt,
    bool? lastCheckinOk,
    String? lastCheckinMessage,
    int? updatedAt,
  }) {
    return Account(
      id: id,
      provider: provider,
      externalId: externalId,
      displayName: displayName ?? this.displayName,
      label: label,
      endpoint: endpoint,
      credential: credential ?? this.credential,
      enabled: enabled ?? this.enabled,
      scheduleEnabled: scheduleEnabled ?? this.scheduleEnabled,
      scheduleTime: scheduleTime ?? this.scheduleTime,
      scheduleLastDate: scheduleLastDate ?? this.scheduleLastDate,
      lastStatus: lastStatus ?? this.lastStatus,
      lastStatusAt: lastStatusAt ?? this.lastStatusAt,
      lastCheckinAt: lastCheckinAt ?? this.lastCheckinAt,
      lastCheckinOk: lastCheckinOk ?? this.lastCheckinOk,
      lastCheckinMessage: lastCheckinMessage ?? this.lastCheckinMessage,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory Account.fromRow(Map<String, Object?> row) {
    Map<String, dynamic>? parseStatus(Object? raw) {
      if (raw == null) return null;
      if (raw is Map<String, dynamic>) return raw;
      try {
        final decoded = jsonDecode(raw.toString());
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        return null;
      }
    }

    return Account(
      id: row['id'] as int,
      provider: PlatformKind.fromId(row['provider'] as String),
      externalId: row['external_id'] as String,
      displayName: (row['display_name'] as String?) ?? '',
      label: (row['label'] as String?) ?? '',
      endpoint: row['endpoint'] as String,
      credential: (row['credential'] as String?) ?? '',
      enabled: (row['enabled'] as int? ?? 1) == 1,
      scheduleEnabled: (row['schedule_enabled'] as int? ?? 1) == 1,
      scheduleTime: (row['schedule_time'] as String?) ?? '09:00',
      scheduleLastDate: row['schedule_last_date'] as String?,
      lastStatus: parseStatus(row['last_status']),
      lastStatusAt: row['last_status_at'] as int?,
      lastCheckinAt: row['last_checkin_at'] as int?,
      lastCheckinOk: row['last_checkin_ok'] == null ? null : (row['last_checkin_ok'] as int) == 1,
      lastCheckinMessage: row['last_checkin_message'] as String?,
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
    );
  }
}
