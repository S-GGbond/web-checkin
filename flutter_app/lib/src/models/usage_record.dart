import 'account.dart';

/// 一条用量记录（一次请求或一个会话的聚合）。
class UsageEntry {
  const UsageEntry({
    required this.provider,
    required this.accountId,
    required this.accountName,
    required this.time,
    required this.title,
    required this.model,
    required this.credits,
    required this.client,
    this.sessionId = '',
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  final PlatformKind provider;
  final int accountId;
  final String accountName;
  final DateTime time;

  /// 会话/请求摘要：Trae 是首个用户输入，WorkBuddy 是输入预览。
  final String title;
  final String model;
  final double credits;

  /// 产品端：TRAE / Web / Mobile / WorkBuddy / CLI。
  final String client;
  final String sessionId;
  final int inputTokens;
  final int outputTokens;
}

/// 单个账号的用量查询结果：[total] 是服务端总数，[entries] 是本次拉到的记录。
class UsageQueryResult {
  const UsageQueryResult({required this.entries, required this.total});

  final List<UsageEntry> entries;
  final int total;

  static const UsageQueryResult empty = UsageQueryResult(entries: [], total: 0);
}

/// 用量页的账号选项：id + 显示名 + 平台。
class UsageAccountRef {
  const UsageAccountRef({
    required this.id,
    required this.name,
    required this.provider,
  });

  final int id;
  final String name;
  final PlatformKind provider;
}

/// 一次用量的加载结果：记录 + 失败账号 + 服务端总数。
class UsageLoadResult {
  const UsageLoadResult({
    required this.entries,
    required this.errors,
    required this.total,
    this.accounts = const [],
  });

  final List<UsageEntry> entries;
  final List<({String account, String message})> errors;
  final int total;

  /// 参与查询的账号（用于页面上的账号筛选）。
  final List<UsageAccountRef> accounts;

  static const UsageLoadResult empty = UsageLoadResult(
    entries: [],
    errors: [],
    total: 0,
  );
}
