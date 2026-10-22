import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/account.dart';
import '../../models/chat_session.dart';
import '../../util/app_paths.dart';

/// Qoder 本地会话：桌面端 main.sqlite + CLI 的 projects/*.jsonl。
class QoderSessionScan {
  const QoderSessionScan({
    required this.sessions,
    required this.databases,
    required this.sources,
  });

  final List<ChatSession> sessions;
  final int databases;
  final List<String> sources;
}

class QoderSessions {
  QoderSessions._();

  static List<String> _configRoots() => [
        p.join(AppPaths.home, '.config'),
        p.join(AppPaths.home, 'Library', 'Application Support'),
        if (Platform.environment['APPDATA'] != null)
          Platform.environment['APPDATA']!,
      ];

  static String? desktopDatabasePath() {
    for (final root in _configRoots()) {
      for (final name in const [
        'com.qodercn.app.stable',
        'com.qodercn.app.canary',
        'Qoder CN',
      ]) {
        final path = p.join(root, name, 'main.sqlite');
        if (File(path).existsSync()) return path;
      }
    }
    return null;
  }

  static List<String> cliRoots() => [
        p.join(AppPaths.home, '.qoder-cn', 'projects'),
        p.join(AppPaths.home, '.qoder', 'projects'),
      ];

  static Future<QoderSessionScan> scan({String uid = ''}) async {
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      return const QoderSessionScan(sessions: [], databases: 0, sources: []);
    }
    final sessions = <String, ChatSession>{};
    final previews = <String, String>{};
    final sources = <String>[];
    var databases = 0;

    final dbPath = desktopDatabasePath();
    if (dbPath != null) {
      databases = 1;
      sources.add(dbPath);
      await _readDesktop(dbPath, uid, sessions, previews);
    }
    for (final root in cliRoots()) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      sources.add(root);
      await _readCli(root, uid, sessions, previews);
    }

    final list = sessions.values.map((session) {
      final preview = previews[session.sessionId];
      if (preview == null || preview.isEmpty) return session;
      return session.copyWith(preview: preview);
    }).toList()
      ..sort((a, b) {
        final left = a.updatedAt?.millisecondsSinceEpoch ?? 0;
        final right = b.updatedAt?.millisecondsSinceEpoch ?? 0;
        return right.compareTo(left);
      });
    return QoderSessionScan(
      sessions: list,
      databases: databases,
      sources: sources,
    );
  }

  static Future<void> _readDesktop(
    String path,
    String uid,
    Map<String, ChatSession> sessions,
    Map<String, String> previews,
  ) async {
    sqfliteFfiInit();
    Database? db;
    try {
      db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final rows = await db.rawQuery(
        'SELECT session_id, title, cwd, model, created_at, updated_at, archived '
        'FROM chat_sessions WHERE deleted_at IS NULL '
        'ORDER BY updated_at DESC',
      );
      final counts = <String, int>{};
      for (final row in await db.rawQuery(
        'SELECT session_id, COUNT(*) AS n FROM chat_session_messages '
        'GROUP BY session_id',
      )) {
        counts[row['session_id']?.toString() ?? ''] =
            (row['n'] as num?)?.toInt() ?? 0;
      }

      for (final row in rows) {
        final id = row['session_id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final title = (row['title'] ?? '').toString().trim();
        final updated = (row['updated_at'] as num?)?.toInt() ?? 0;
        final created = (row['created_at'] as num?)?.toInt() ?? 0;
        sessions[id] = ChatSession(
          provider: PlatformKind.qoder,
          accountUid: uid,
          workspaceId: '',
          sessionId: id,
          title: title.isEmpty ? '（无标题）' : title,
          createdAt: _iso(created),
          lastMessageAt: _iso(updated),
          messageCount: counts[id] ?? 0,
          source: SessionSource.qoder,
          project: (row['cwd'] ?? '').toString(),
          cwd: (row['cwd'] ?? '').toString(),
          model: (row['model'] ?? '').toString(),
          path: path,
          origin: const ['desktop'],
        );

        try {
          final last = await db.query(
            'chat_session_messages',
            columns: const ['payload_json'],
            where: 'session_id = ?',
            whereArgs: [id],
            orderBy: 'sequence DESC',
            limit: 1,
          );
          if (last.isNotEmpty) {
            previews[id] = _preview(last.first['payload_json']?.toString() ?? '');
          }
        } catch (_) {
          // 老版本库没有这张表时忽略。
        }
      }
    } catch (_) {
      // 库被占用 / 结构不符时跳过桌面端。
    } finally {
      try {
        await db?.close();
      } catch (_) {
        // 忽略。
      }
    }
  }

  static Future<void> _readCli(
    String root,
    String uid,
    Map<String, ChatSession> sessions,
    Map<String, String> previews,
  ) async {
    final List<FileSystemEntity> projects;
    try {
      projects = await Directory(root).list().toList();
    } catch (_) {
      return;
    }
    for (final project in projects) {
      if (project is! Directory) continue;
      final List<FileSystemEntity> files;
      try {
        files = await project.list().toList();
      } catch (_) {
        continue;
      }
      for (final entity in files) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
        final id = p.basenameWithoutExtension(entity.path);
        String title = '';
        String model = '';
        String cwd = '';
        String lastPrompt = '';
        var count = 0;
        var lastTs = 0;
        try {
          final lines = await entity.readAsLines();
          for (final line in lines) {
            if (line.trim().isEmpty) continue;
            Map<String, dynamic> data;
            try {
              final decoded = jsonDecode(line);
              if (decoded is! Map) continue;
              data = decoded.cast<String, dynamic>();
            } catch (_) {
              continue;
            }
            final type = data['type']?.toString() ?? '';
            if (type == 'runtime-config' && data['model'] != null) {
              model = data['model'].toString();
            } else if (type == 'workspace-directories') {
              final dirs = data['directories'];
              if (dirs is List && dirs.isNotEmpty) cwd = dirs.first.toString();
            } else if (type == 'last-prompt' && data['lastPrompt'] != null) {
              lastPrompt = data['lastPrompt'].toString();
            } else if (type == 'user' || type == 'assistant') {
              count++;
              if (data['cwd'] != null) cwd = data['cwd'].toString();
              final message = data['message'] is Map
                  ? (data['message'] as Map)
                  : const {};
              if (type == 'user' && message['role'] == 'user' && title.isEmpty) {
                final text = _textOf(message['content']).trim();
                if (text.isNotEmpty) {
                  title = text.replaceAll(RegExp(r'\s+'), ' ');
                  if (title.length > 60) title = title.substring(0, 60);
                }
              }
              final stamp = DateTime.tryParse(
                (data['timestamp'] ?? '').toString().replaceFirst('Z', '+00:00'),
              );
              if (stamp != null && stamp.millisecondsSinceEpoch > lastTs) {
                lastTs = stamp.millisecondsSinceEpoch;
              }
            }
          }
        } catch (_) {
          continue;
        }

        final existing = sessions[id];
        if (existing != null) {
          sessions[id] = existing.copyWith(
            title: existing.title == '（无标题）' && title.isNotEmpty
                ? title
                : existing.title,
            origin: [...existing.origin, 'cli'],
          );
          continue;
        }
        if (count == 0 && title.isEmpty) continue;
        var modified = 0;
        try {
          modified = (await entity.stat()).modified.millisecondsSinceEpoch;
        } catch (_) {
          modified = 0;
        }
        final at = lastTs > 0 ? lastTs : modified;
        sessions[id] = ChatSession(
          provider: PlatformKind.qoder,
          accountUid: uid,
          workspaceId: '',
          sessionId: id,
          title: title.isEmpty ? '（无标题）' : title,
          createdAt: '',
          lastMessageAt: _iso(at),
          messageCount: count,
          source: SessionSource.qoder,
          project: cwd,
          cwd: cwd,
          model: model,
          preview: lastPrompt.replaceAll(RegExp(r'\s+'), ' '),
          path: entity.path,
          origin: const ['cli'],
        );
      }
    }
  }

  /// 读一组会话正文：桌面端读 SQLite，CLI 读 JSONL。
  static Future<List<ChatMessage>> messages(ChatSession session) async {
    final path = session.path;
    if (path.isEmpty) return const [];
    if (path.endsWith('.jsonl')) return _cliMessages(path);
    return _desktopMessages(path, session.sessionId);
  }

  static Future<List<ChatMessage>> _desktopMessages(
    String dbPath,
    String sessionId,
  ) async {
    sqfliteFfiInit();
    Database? db;
    try {
      db = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final rows = await db.query(
        'chat_session_messages',
        columns: const ['payload_json', 'created_at'],
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'sequence',
      );
      final messages = <ChatMessage>[];
      for (final row in rows) {
        final raw = row['payload_json']?.toString() ?? '';
        Map<String, dynamic> payload;
        try {
          final decoded = jsonDecode(raw);
          payload = decoded is Map ? decoded.cast<String, dynamic>() : const {};
        } catch (_) {
          continue;
        }
        final message = payload['message'] is Map
            ? (payload['message'] as Map)
            : const {};
        final text = (payload['text'] ?? _textOf(message['content']))
            .toString()
            .trim();
        if (text.isEmpty) continue;
        final created = (row['created_at'] as num?)?.toInt() ?? 0;
        messages.add(
          ChatMessage(
            role: (payload['role'] ?? message['role'] ?? '').toString(),
            text: text,
            createdAt: _time(_iso(created)),
          ),
        );
      }
      return messages;
    } catch (_) {
      return const [];
    } finally {
      try {
        await db?.close();
      } catch (_) {
        // 忽略。
      }
    }
  }

  static Future<List<ChatMessage>> _cliMessages(String path) async {
    final messages = <ChatMessage>[];
    try {
      final lines = await File(path).readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        Map<String, dynamic> data;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map) continue;
          data = decoded.cast<String, dynamic>();
        } catch (_) {
          continue;
        }
        final type = data['type']?.toString() ?? '';
        if (type != 'user' && type != 'assistant') continue;
        final message = data['message'] is Map
            ? (data['message'] as Map)
            : const {};
        final text = _textOf(message['content']).trim();
        if (text.isEmpty) continue;
        messages.add(
          ChatMessage(
            role: (message['role'] ?? type).toString(),
            text: text,
            createdAt: _time((data['timestamp'] ?? '').toString()),
          ),
        );
      }
    } catch (_) {
      // 忽略。
    }
    return messages;
  }

  static String _textOf(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final parts = <String>[];
      for (final block in content) {
        if (block is Map && block['type'] == 'text' && block['text'] != null) {
          parts.add(block['text'].toString());
        }
      }
      return parts.join('\n');
    }
    return '';
  }

  static String _preview(String raw) {
    if (raw.isEmpty) return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return '';
      final text = decoded['text'] ??
          _textOf(
            decoded['message'] is Map
                ? (decoded['message'] as Map)['content']
                : null,
          );
      return text.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    } catch (_) {
      return '';
    }
  }

  static DateTime? _time(String value) {
    if (value.isEmpty) return null;
    return DateTime.tryParse(value.replaceFirst('Z', '+00:00'))?.toLocal();
  }

  static String _iso(int milliseconds) {
    if (milliseconds <= 0) return '';
    return DateTime.fromMillisecondsSinceEpoch(milliseconds).toIso8601String();
  }
}
