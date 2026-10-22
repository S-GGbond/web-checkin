import 'dart:convert';
import 'dart:io';

import 'package:checkin_hub/src/models/chat_session.dart';
import 'package:checkin_hub/src/services/sessions/session_service.dart';
import 'package:checkin_hub/src/services/sessions/workbuddy_packer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 造一个带一条会话的 WorkBuddy 目录（workbuddy.db + projects/<项目>/<会话>.jsonl）。
Future<void> _buildWorkbuddy(
  String root, {
  required String cwd,
  required String title,
  required String uid,
}) async {
  final dir = Directory(p.join(root, 'projects', WorkbuddyPacker.slug(cwd)));
  await dir.create(recursive: true);
  await File(p.join(dir.path, 'sess-1.jsonl')).writeAsString(
    [
      jsonEncode({
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': title},
        ],
        'timestamp': 1792378134970,
      }),
      jsonEncode({
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': '回答：$title'},
        ],
        'timestamp': 1792378135970,
      }),
    ].join('\n'),
  );

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    p.join(root, 'workbuddy.db'),
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute(
    'CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, user_id TEXT, '
    'title TEXT, custom_title TEXT, status TEXT, created_at INTEGER, '
    'updated_at INTEGER, last_activity_at INTEGER, deleted_at INTEGER, '
    'model TEXT)',
  );
  await db.insert('sessions', {
    'id': 'sess-1',
    'cwd': cwd,
    'user_id': uid,
    'title': title,
    'status': 'completed',
    'created_at': 1792378134970,
    'updated_at': 1792378135970,
    'last_activity_at': 1792378135970,
  });
  await db.close();
}

void main() {
  const service = SessionService();
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('wb-pack-test-');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 忽略。
    }
  });

  test('导出会话包，再导入到另一份 WorkBuddy 目录', () async {
    const cwd = '/home/chen/Project/demo';
    final source = p.join(temp.path, 'src');
    await _buildWorkbuddy(source, cwd: cwd, title: '被导出的会话', uid: 'uid-a');

    final scan = await service.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: '/nonexistent',
      traeRoots: const [],
      scanQoder: false,
      appRoot: source,
    );
    final session = scan.sessions.single;

    final packPath = p.join(temp.path, 'pack.json');
    final packed = await const WorkbuddyPacker().pack(
      sessions: [session],
      readMessages: service.readMessages,
      outputPath: packPath,
    );
    expect(packed.sessions, 1);
    expect(File(packPath).existsSync(), isTrue);
    final json =
        jsonDecode(File(packPath).readAsStringSync()) as Map<String, dynamic>;
    expect(json['format'], WorkbuddyPacker.format);
    final messages =
        (json['sessions'] as List).first['messages'] as List<dynamic>;
    expect(messages, hasLength(2));

    expect(
      (json['sessions'] as List).first['userId'],
      'uid-a',
      reason: '包里要带来源账号，导入时才能沿用',
    );

    // 目标机器：另一份空的 WorkBuddy 目录。
    final target = p.join(temp.path, 'dst');
    await _buildWorkbuddy(target, cwd: cwd, title: '占位', uid: 'uid-b');
    final imported = await const WorkbuddyPacker().import(
      fromPath: packPath,
      appRoot: target,
      targetUid: 'uid-b',
    );
    expect(imported, 1);

    final rescanned = await service.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: '/nonexistent',
      traeRoots: const [],
      scanQoder: false,
      appRoot: target,
    );
    final importedSession = rescanned.sessions.firstWhere(
      (item) => item.title == '被导出的会话',
    );
    expect(importedSession.accountUid, 'uid-b');
    expect(importedSession.messageCount, 2);
    expect(importedSession.source, SessionSource.workbuddyApp);
  });

  test('不是会话包时明确报错', () async {
    final bad = p.join(temp.path, 'bad.json');
    await File(bad).writeAsString('{"format":"other"}');
    expect(
      () => const WorkbuddyPacker().import(
        fromPath: bad,
        appRoot: temp.path,
      ),
      throwsA(isA<WorkbuddyPackException>()),
    );
  });
}
