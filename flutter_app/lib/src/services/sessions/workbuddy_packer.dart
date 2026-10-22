import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/chat_session.dart';
import '../../util/app_paths.dart';
import 'session_service.dart';

/// 导出 / 导入 WorkBuddy 家族的会话包（明文 JSON，跨机器搬运用）。
///
/// 包里只有会话元数据与消息正文，不包含账号凭证；导入时会写成 WorkBuddy
/// 客户端自己的存储（`workbuddy.db` 的 `sessions` 行 + `projects/<项目>/<会话>.jsonl`）。
class WorkbuddyPackResult {
  const WorkbuddyPackResult({
    required this.path,
    required this.sessions,
    required this.sizeBytes,
  });

  final String path;
  final int sessions;
  final int sizeBytes;
}

class WorkbuddyPackException implements Exception {
  const WorkbuddyPackException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WorkbuddyPacker {
  const WorkbuddyPacker();

  static const String format = 'checkin-hub/workbuddy-sessions';

  /// 导出选中的会话；[readMessages] 由会话服务提供（不同来源读法不同）。
  Future<WorkbuddyPackResult> pack({
    required List<ChatSession> sessions,
    required Future<List<ChatMessage>> Function(ChatSession) readMessages,
    String? outputPath,
  }) async {
    if (sessions.isEmpty) {
      throw const WorkbuddyPackException('没有选中任何会话');
    }
    final payload = <Map<String, dynamic>>[];
    for (final session in sessions) {
      final messages = await readMessages(session);
      payload.add({
        'sessionId': session.sessionId,
        'title': session.title,
        'cwd': session.cwd.isNotEmpty ? session.cwd : session.project,
        'userId': session.accountUid,
        'createdAt': session.createdAt,
        'lastMessageAt': session.lastMessageAt,
        'source': session.source.id,
        'model': session.model,
        'status': session.status,
        'messages': [
          for (final message in messages)
            {
              'role': message.role,
              'text': message.text,
              'createdAt': message.createdAt?.toUtc().toIso8601String(),
            },
        ],
      });
    }

    final out = outputPath ?? _defaultPackPath();
    final file = File(out);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format': format,
        'version': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'sessions': payload,
      }),
    );
    return WorkbuddyPackResult(
      path: out,
      sessions: payload.length,
      sizeBytes: await file.length(),
    );
  }

  /// 把会话包写进本机 WorkBuddy 客户端；返回写入条数。
  ///
  /// [targetUid] 不传时沿用包里的来源账号（同账号跨机器恢复）。
  /// [dryRun] 只解析不落盘。
  Future<int> import({
    required String fromPath,
    String? appRoot,
    String? targetUid,
    bool dryRun = false,
  }) async {
    final file = File(fromPath);
    if (!await file.exists()) {
      throw WorkbuddyPackException('文件不存在：$fromPath');
    }

    Map<String, dynamic> decoded;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) throw const FormatException('不是对象');
      decoded = value.cast<String, dynamic>();
    } catch (_) {
      throw const WorkbuddyPackException('不是有效的会话包（JSON 解析失败）');
    }
    if (decoded['format'] != format) {
      throw const WorkbuddyPackException('不是 WorkBuddy 会话包');
    }
    final sessions = decoded['sessions'];
    if (sessions is! List || sessions.isEmpty) {
      throw const WorkbuddyPackException('包里没有会话');
    }

    final root = appRoot ?? SessionService.workbuddyAppRoot();
    if (root == null) {
      throw const WorkbuddyPackException('没有找到 WorkBuddy 数据目录（~/.workbuddy）');
    }
    final dbPath = p.join(root, 'workbuddy.db');
    if (!await File(dbPath).exists()) {
      throw WorkbuddyPackException('WorkBuddy 会话库不存在：$dbPath');
    }

    if (dryRun) return sessions.length;

    final projectsRoot = p.join(root, 'projects');
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    var imported = 0;
    try {
      for (final raw in sessions) {
        if (raw is! Map) continue;
        final cwd = raw['cwd']?.toString() ?? '';
        if (cwd.isEmpty) continue;
        final messages = raw['messages'];
        if (messages is! List || messages.isEmpty) continue;

        final newId = _uuid();
        final created =
            DateTime.tryParse(raw['createdAt']?.toString() ?? '') ??
            DateTime.now().toUtc();
        final updated =
            DateTime.tryParse(raw['lastMessageAt']?.toString() ?? '') ??
            created;

        final dir = Directory(p.join(projectsRoot, slug(cwd)));
        await dir.create(recursive: true);
        final buffer = StringBuffer();
        for (final message in messages) {
          if (message is! Map) continue;
          final role = message['role']?.toString() ?? 'user';
          final text = message['text']?.toString() ?? '';
          if (text.isEmpty) continue;
          final at =
              DateTime.tryParse(message['createdAt']?.toString() ?? '') ??
              created;
          buffer.writeln(
            jsonEncode({
              'id': _uuid(),
              'timestamp': at.millisecondsSinceEpoch,
              'type': 'message',
              'role': role,
              'content': [
                {
                  'type': role == 'user' ? 'input_text' : 'output_text',
                  'text': text,
                },
              ],
              'sessionId': newId,
              'cwd': cwd,
            }),
          );
        }
        if (buffer.isEmpty) continue;
        await File(p.join(dir.path, '$newId.jsonl')).writeAsString('$buffer');

        await db.insert('sessions', {
          'id': newId,
          'cwd': cwd,
          'user_id': (targetUid != null && targetUid.isNotEmpty)
              ? targetUid
              : (raw['userId']?.toString() ?? ''),
          'title': raw['title']?.toString() ?? '',
          'status': 'completed',
          'created_at': created.millisecondsSinceEpoch,
          'updated_at': updated.millisecondsSinceEpoch,
          'last_activity_at': updated.millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        imported++;
      }
    } finally {
      await db.close();
    }
    return imported;
  }

  /// 客户端按 `projects/<cwd 去分隔符>` 归档会话。
  static String slug(String cwd) {
    var value = cwd.trim();
    value = value.replaceAll(RegExp(r'^[\\/]+'), '');
    value = value.replaceAll(RegExp(r'[:\\/]+'), '-');
    return value.isEmpty ? 'root' : value;
  }

  static String _defaultPackPath() {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp('[:.T-]'), '')
        .substring(0, 15);
    return p.join(AppPaths.home, 'workbuddy-sessions-$stamp.json');
  }

  static String _uuid() {
    final random = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => random.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }
}
