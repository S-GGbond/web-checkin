import 'account.dart';

/// 会话来自哪个本地数据源。
enum SessionSource {
  /// WorkBuddy / CodeBuddy 桌面端：`Data/<账号>/CodeBuddyIDE/<账号>/history/<工作区>/<会话>`。
  workbuddyDesktop('workbuddyDesktop', '桌面端'),

  /// CodeBuddy CLI：`~/.codebuddy/projects/<项目>/<会话>.jsonl`。
  workbuddyCli('workbuddyCli', 'CLI'),

  /// Trae 桌面端：状态库 + 快照/沙箱目录 + 渲染进程日志聚合。
  trae('trae', 'Trae');

  const SessionSource(this.id, this.label);

  final String id;
  final String label;

  static SessionSource fromId(String? id) {
    return SessionSource.values.firstWhere(
      (s) => s.id == id,
      orElse: () => SessionSource.workbuddyDesktop,
    );
  }
}

/// 一条本地 AI 会话（来自客户端的数据目录，不是账号库）。
class ChatSession {
  const ChatSession({
    required this.provider,
    required this.accountUid,
    required this.workspaceId,
    required this.sessionId,
    required this.title,
    required this.createdAt,
    required this.lastMessageAt,
    required this.messageCount,
    this.source = SessionSource.workbuddyDesktop,
    this.project = '',
    this.agent = '',
    this.model = '',
    this.preview = '',
    this.cwd = '',
    this.status = '',
    this.path = '',
    this.origin = const [],
  });

  final PlatformKind provider;

  /// 会话所属账号（客户端用户目录名 / UserID）；空串表示本机级数据，未关联账号。
  final String accountUid;

  /// 工作区 id（客户端用路径哈希命名）；CLI 与 Trae 会话为空。
  final String workspaceId;

  final String sessionId;
  final String title;

  /// 原始 ISO 时间串，同步时原样写回客户端。
  final String createdAt;
  final String lastMessageAt;

  final int messageCount;

  final SessionSource source;

  /// 会话所属项目：桌面端为工作区名，CLI 为工作目录，Trae 为空。
  final String project;

  /// Trae 的会话类型（例如 `solo_agent`）。
  final String agent;

  /// 会话使用的模型名（Trae 状态库里记录）。
  final String model;

  /// 最后一条回复的摘要（Trae 状态库只留了这一段正文）。
  final String preview;

  /// 会话工作目录（桌面端元数据 / CLI 事件里的 cwd）。
  final String cwd;

  /// 桌面端元数据里的会话状态。
  final String status;

  /// 会话在本机的落盘位置：桌面端为会话目录，CLI 为 jsonl 文件。
  final String path;

  /// Trae 会话被哪些数据源命中（vscdb / snapshot / sandbox / log）。
  final List<String> origin;

  String get key =>
      '${provider.id}:${source.id}:$accountUid:$workspaceId:$sessionId';

  String get workspaceShort =>
      workspaceId.length <= 8 ? workspaceId : workspaceId.substring(0, 8);

  /// 只有桌面端、且能定位到账号数据目录的会话才能复制到另一个账号。
  bool get copyable =>
      source == SessionSource.workbuddyDesktop &&
      accountUid.isNotEmpty &&
      workspaceId.isNotEmpty;

  /// 是否具备可展示的正文（Trae 的正文在加密库里，只有一段预览）。
  bool get hasBody => source != SessionSource.trae;

  /// 能整条搬到另一个 WorkBuddy 账号：
  /// 桌面端直接复制会话目录，CLI 会话转成桌面端会话写进目标账号。
  bool get accountMigratable =>
      provider == PlatformKind.workbuddy &&
      (copyable || source == SessionSource.workbuddyCli);

  /// Trae 会话可以整段导出成迁移包，再到别的机器合并回客户端。
  bool get migratable => source == SessionSource.trae;

  DateTime? get updatedAt =>
      DateTime.tryParse(lastMessageAt) ?? DateTime.tryParse(createdAt);

  /// 项目名：只取路径最后一段，界面里更省空间。
  String get projectLabel {
    final value = project.isNotEmpty ? project : cwd;
    if (value.isEmpty) return '';
    final parts = value
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return value;
    return parts.last;
  }

  /// 来源标签：Trae 会话会标出命中的本地数据源。
  String get sourceLabel {
    if (origin.isEmpty) return source.label;
    const names = {
      'vscdb': '状态库',
      'snapshot': '快照',
      'sandbox': '沙箱',
      'log': '日志',
    };
    return origin.map((tag) => names[tag] ?? tag).join(' + ');
  }

  ChatSession copyWith({
    String? title,
    String? createdAt,
    String? lastMessageAt,
    int? messageCount,
    String? project,
    String? agent,
    String? model,
    String? preview,
    String? cwd,
    String? status,
    String? path,
    List<String>? origin,
  }) {
    return ChatSession(
      provider: provider,
      accountUid: accountUid,
      workspaceId: workspaceId,
      sessionId: sessionId,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      messageCount: messageCount ?? this.messageCount,
      source: source,
      project: project ?? this.project,
      agent: agent ?? this.agent,
      model: model ?? this.model,
      preview: preview ?? this.preview,
      cwd: cwd ?? this.cwd,
      status: status ?? this.status,
      path: path ?? this.path,
      origin: origin ?? this.origin,
    );
  }
}

/// 会话里的一条消息。
class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.createdAt});

  final String role;
  final String text;
  final DateTime? createdAt;
}
