import 'dart:io';

import 'package:checkin_hub/src/services/sessions/trae_chat_db.dart';
import 'package:checkin_hub/src/services/sessions/trae_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/trae_fixture.dart';

/// 会话迁移：导出明文包、增量合并、重新加密与备份。
void main() {
  const srcKey =
      '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
  const dstKey =
      'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
  const migrator = TraeMigrator();

  late Directory temp;

  setUp(() async {
    sqfliteFfiInit();
    temp = await Directory.systemTemp.createTemp('trae-migrate-test-');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 忽略。
    }
  });

  Future<String> encrypted(String plainPath, String key, String name) async {
    final path = p.join(temp.path, name);
    File(path).writeAsBytesSync(
      encryptFixture(File(plainPath).readAsBytesSync(), key),
    );
    return path;
  }

  Future<List<Map<String, Object?>>> rows(String path, String table) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      return await db.query(table);
    } finally {
      await db.close();
    }
  }

  test('pack 导出可读的明文包', () async {
    final plain = await buildPlainTraeDb(
      dir: temp,
      name: 'src-plain.db',
      sessions: const [
        FixtureSession(
          id: 'sess-a',
          title: '源机会话',
          messages: [('user', '你好'), ('assistant', '在的')],
        ),
      ],
    );
    final source = await encrypted(plain, srcKey, 'src-enc.db');
    final out = p.join(temp.path, 'pack.db');

    final result = await migrator.pack(
      dbPath: source,
      outputPath: out,
      key: srcKey,
    );

    expect(result.sessions, 1);
    expect(File(out).existsSync(), isTrue);
    expect(result.sizeBytes, greaterThan(0));
    // 明文包是普通 SQLite，直接可读。
    final packRows = await rows(out, 'chat_session');
    expect(packRows.single['session_id'], 'sess-a');

    // 原加密库没被改动，仍可用原 key 读取。
    final db = await TraeChatDb.open(dbPath: source, key: srcKey);
    addTearDown(db.close);
    expect(await db.messages('sess-a'), isNotEmpty);
  });

  test('pack 只导出勾选的会话', () async {
    final plain = await buildPlainTraeDb(
      dir: temp,
      name: 'src-multi.db',
      sessions: const [
        FixtureSession(
          id: 'keep-me',
          title: '要导出的',
          messages: [('user', '这条要带走')],
        ),
        FixtureSession(
          id: 'leave-me',
          title: '不导出的',
          messages: [('user', '这条留下')],
        ),
      ],
    );
    final source = await encrypted(plain, srcKey, 'src-multi-enc.db');
    final out = p.join(temp.path, 'one.db');

    final result = await migrator.pack(
      dbPath: source,
      outputPath: out,
      key: srcKey,
      sessionIds: const {'keep-me'},
    );

    expect(result.sessions, 1);
    final sessions = await rows(out, 'chat_session');
    expect(sessions.map((r) => r['session_id']).toList(), ['keep-me']);
    final messages = await rows(out, 'chat_message');
    expect(messages.every((r) => r['session_id'] == 'keep-me'), isTrue);
  });

  test('merge 只导入新会话，并重新加密目标库', () async {
    final sourcePlain = await buildPlainTraeDb(
      dir: temp,
      name: 'src.db',
      sessions: const [
        FixtureSession(
          id: 'sess-a',
          title: '源机 A',
          messages: [('user', '源机的问题')],
        ),
        FixtureSession(
          id: 'sess-b',
          title: '源机 B',
          messages: [('user', '只在新包里'), ('assistant', '收到')],
        ),
      ],
    );
    final targetPlain = await buildPlainTraeDb(
      dir: temp,
      name: 'dst.db',
      sessions: const [
        FixtureSession(
          id: 'sess-a',
          title: '目标机已有的 A',
          messages: [('user', '旧消息')],
        ),
      ],
    );
    final target = await encrypted(targetPlain, dstKey, 'dst-enc.db');
    final before = File(target).readAsBytesSync();

    final result = await migrator.merge(
      fromPath: sourcePlain,
      dbPath: target,
      dstKey: dstKey,
      requireClientClosed: false,
    );

    expect(result.sourceSessions, 2);
    expect(result.newSessions, 1);
    expect(result.rows, greaterThan(0));
    expect(result.backupPath, isNotNull);
    expect(File(result.backupPath!).existsSync(), isTrue);
    // 备份就是替换前的字节。
    expect(
      File(result.backupPath!).readAsBytesSync(),
      equals(before),
    );

    final db = await TraeChatDb.open(dbPath: target, key: dstKey);
    addTearDown(db.close);
    final imported = await db.messages('sess-b');
    expect(imported.map((m) => m.text).toList(), ['只在新包里', '收到']);
    // 已存在的会话保持目标机版本，不被源包覆盖。
    final existing = await db.messages('sess-a');
    expect(existing.map((m) => m.text).toList(), ['旧消息']);
  });

  test('copy 复制整条会话图到目标账号，原会话保留', () async {
    final plain = await _buildCopyPlain(temp, 'copy.db');
    final target = await encrypted(plain, dstKey, 'copy-enc.db');

    final result = await migrator.copySessions(
      fromUid: 'uid-old',
      toUid: 'uid-new',
      dbPath: target,
      key: dstKey,
      sessionIds: const {'s1'},
      requireClientClosed: false,
      stateRoots: const [],
    );

    expect(result.sessions, 1);
    expect(result.rows, greaterThan(0));
    expect(result.backupPath, isNotNull);
    expect(File(result.backupPath!).existsSync(), isTrue);
    expect(result.projectPaths, contains('/w'));
    final newId = result.newSessionIds['s1'];
    expect(newId, isNotNull);
    expect(newId, isNot('s1'));

    final dump = await Directory(
      p.join(temp.path, 'verify'),
    ).create(recursive: true);
    final plainDump = await TraeChatDb.decryptToPlain(dstKey, target, dump);
    final db = await databaseFactoryFfi.openDatabase(
      plainDump,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final sessions = await db.query('chat_session');
      expect(sessions, hasLength(2));
      final origin = sessions.firstWhere((row) => row['session_id'] == 's1');
      expect(origin['project_id'], 'p-old');
      expect(origin['session_title'], '原会话');

      final copy = sessions.firstWhere((row) => row['session_id'] == newId);
      expect(copy['project_id'], 'p-new');
      expect(copy['session_title'], '原会话');
      final context = copy['context'].toString();
      expect(context, contains('p-new'));
      expect(context, contains(newId!));
      expect(context, isNot(contains('p-old')));
      expect(context, isNot(contains('"s1"')));

      final messages = await db.query(
        'chat_message',
        orderBy: 'message_index',
      );
      expect(messages, hasLength(4));
      final copies = messages
          .where((row) => row['session_id'] == newId)
          .toList();
      expect(copies, hasLength(2));
      expect(copies.map((row) => row['message_id']), isNot(contains('m1')));
      // 回复关系也指到副本自己的上一条消息。
      final first = copies.firstWhere((row) => row['message_index'] == 1);
      final second = copies.firstWhere((row) => row['message_index'] == 2);
      expect(second['reply_to_message_id'], first['message_id']);

      final contents = await db.query('chat_message_general');
      expect(contents, hasLength(4));
      expect(contents.map((row) => row['content']).toSet(), {'你好', '在的'});

      final links = await db.query('session_project');
      expect(links, hasLength(2));
      expect(
        links.map((row) => '::${row['session_id']}::${row['project_id']}').toSet(),
        {'::s1::p-old', '::$newId::p-new'},
      );

      final history = await db.query('history_v2');
      expect(history, hasLength(2));
      final historyCopy = history.firstWhere(
        (row) => row['session_id'] == newId,
      );
      expect(historyCopy['message_id'], second['message_id']);
      expect(historyCopy['history_v2_id'], isNot('h1'));

      final tasks = await db.query('task');
      expect(tasks, hasLength(2));
      final taskCopy = tasks.firstWhere((row) => row['session_id'] == newId);
      expect(taskCopy['task_id'], isNot('tk1'));

      final runs = await db.query('agent_run');
      expect(runs, hasLength(2));
      final runCopy = runs.firstWhere((row) => row['session_id'] == newId);
      expect(runCopy['agent_run_id'], isNot('ar1'));

      final server = await db.query('server_history_info');
      expect(server, hasLength(2));
      final serverCopy = server.firstWhere(
        (row) => row['history_id'] != 'hi1',
      );
      expect(serverCopy['task_id'], taskCopy['task_id']);
      expect(serverCopy['agent_run_id'], runCopy['agent_run_id']);
      expect(serverCopy['history_id'], isNot('hi1'));

      // 账号级记忆不复制；目标账号的现有项目行保持自己的云端绑定。
      final memories = await db.query('core_memory');
      expect(memories, hasLength(1));
      expect(memories.single['user_id'], 'uid-old');

      final projects = await db.query('project');
      expect(projects, hasLength(2));
      final targetProject = projects.firstWhere(
        (row) => row['project_id'] == 'p-new',
      );
      expect(targetProject['user_id'], 'uid-new');
      expect(targetProject['biz_project_id'], 'biz-new');
    } finally {
      await db.close();
    }
  });

  test('copy 目标账号没有同路径项目时新建一行', () async {
    final plain = await _buildCopyPlain(
      temp,
      'copy-new-project.db',
      withTargetProject: false,
    );
    final target = await encrypted(plain, dstKey, 'copy-new-project-enc.db');

    final result = await migrator.copySessions(
      toUid: 'uid-new',
      dbPath: target,
      key: dstKey,
      sessionIds: const {'s1'},
      requireClientClosed: false,
      stateRoots: const [],
    );

    expect(result.sessions, 1);
    expect(result.createdProjects, 1);

    final dump = await Directory(
      p.join(temp.path, 'verify-project'),
    ).create(recursive: true);
    final plainDump = await TraeChatDb.decryptToPlain(dstKey, target, dump);
    final db = await databaseFactoryFfi.openDatabase(
      plainDump,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final projects = await db.query('project');
      expect(projects, hasLength(2));
      final created = projects.firstWhere(
        (row) => row['user_id'] == 'uid-new',
      );
      expect(created['project_id'], isNot('p-old'));
      expect(created['absolute_path'], '/w');
      expect(created['biz_project_id'], isNot('biz-old'));

      final copy = await db.query(
        'chat_session',
        where: 'session_id = ?',
        whereArgs: [result.newSessionIds['s1']],
      );
      expect(copy.single['project_id'], created['project_id']);
    } finally {
      await db.close();
    }
  });

  test('copy dryRun 不改动目标库', () async {
    final plain = await _buildCopyPlain(temp, 'copy-dry.db');
    final target = await encrypted(plain, dstKey, 'copy-dry-enc.db');
    final before = File(target).readAsBytesSync();

    final result = await migrator.copySessions(
      toUid: 'uid-new',
      dbPath: target,
      key: dstKey,
      sessionIds: const {'s1'},
      dryRun: true,
      requireClientClosed: false,
      stateRoots: const [],
    );

    expect(result.dryRun, isTrue);
    expect(result.sessions, 1);
    expect(result.backupPath, isNull);
    expect(File(target).readAsBytesSync(), equals(before));
  });
}

/// 一份带项目归属与整条会话图的明文库，用来验证复制。
Future<String> _buildCopyPlain(
  Directory dir,
  String name, {
  bool withTargetProject = true,
}) async {
  final path = p.join(dir.path, name);
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute(
    'CREATE TABLE project (project_id TEXT PRIMARY KEY, user_id TEXT, '
    'absolute_path TEXT, biz_project_id TEXT, name TEXT, created_at INTEGER, '
    'updated_at INTEGER, deleted_at INTEGER)',
  );
  await db.execute(
    'CREATE TABLE chat_session (session_id TEXT PRIMARY KEY, project_id TEXT, '
    'session_title TEXT, context TEXT, created_at INTEGER, updated_at INTEGER, '
    'deleted_at INTEGER DEFAULT 0)',
  );
  await db.execute(
    'CREATE TABLE session_project (session_id TEXT, project_id TEXT)',
  );
  await db.execute(
    'CREATE TABLE chat_message (message_id TEXT PRIMARY KEY, session_id TEXT, '
    'message_role TEXT, message_index INTEGER, reply_to_message_id TEXT, '
    'deleted_at INTEGER DEFAULT 0)',
  );
  await db.execute(
    'CREATE TABLE chat_message_general (message_id TEXT, content TEXT, '
    'deleted_at INTEGER DEFAULT 0)',
  );
  await db.execute(
    'CREATE TABLE chat_turn (turn_id TEXT, session_id TEXT, '
    'reply_to_message_id TEXT, response_message_id TEXT, context TEXT, '
    'deleted_at INTEGER DEFAULT 0)',
  );
  await db.execute(
    'CREATE TABLE history_v2 (history_v2_id TEXT, session_id TEXT, '
    'message_id TEXT, messages TEXT)',
  );
  await db.execute(
    'CREATE TABLE task (task_id TEXT, session_id TEXT, message_id TEXT, '
    'status TEXT)',
  );
  await db.execute(
    'CREATE TABLE agent_run (agent_run_id TEXT, session_id TEXT, agent_id TEXT)',
  );
  await db.execute(
    'CREATE TABLE server_history_info (history_id TEXT PRIMARY KEY, '
    'client_history_id TEXT, session_id TEXT, task_id TEXT, agent_run_id TEXT)',
  );
  await db.execute(
    'CREATE TABLE core_memory (id INTEGER PRIMARY KEY, user_id TEXT, '
    'project_id TEXT)',
  );

  await db.insert('project', {
    'project_id': 'p-old',
    'user_id': 'uid-old',
    'absolute_path': '/w',
    'biz_project_id': 'biz-old',
    'name': 'work',
    'created_at': 1,
    'updated_at': 1,
    'deleted_at': 0,
  });
  if (withTargetProject) {
    await db.insert('project', {
      'project_id': 'p-new',
      'user_id': 'uid-new',
      'absolute_path': '/w',
      'biz_project_id': 'biz-new',
      'name': 'work',
      'created_at': 1,
      'updated_at': 1,
      'deleted_at': 0,
    });
  }

  await db.insert('chat_session', {
    'session_id': 's1',
    'project_id': 'p-old',
    'session_title': '原会话',
    'context': '{"last_real_project_id":"p-old","skill_revision_s1":"x"}',
    'created_at': 1,
    'updated_at': 1,
  });
  await db.insert('session_project', {
    'session_id': 's1',
    'project_id': 'p-old',
  });
  await db.insert('chat_message', {
    'message_id': 'm1',
    'session_id': 's1',
    'message_role': 'user',
    'message_index': 1,
    'reply_to_message_id': '',
  });
  await db.insert('chat_message', {
    'message_id': 'm2',
    'session_id': 's1',
    'message_role': 'assistant',
    'message_index': 2,
    'reply_to_message_id': 'm1',
  });
  await db.insert('chat_message_general', {
    'message_id': 'm1',
    'content': '你好',
  });
  await db.insert('chat_message_general', {
    'message_id': 'm2',
    'content': '在的',
  });
  await db.insert('chat_turn', {
    'turn_id': 't1',
    'session_id': 's1',
    'reply_to_message_id': 'm1',
    'response_message_id': 'm2',
    'context': '{"project":"p-old"}',
  });
  await db.insert('history_v2', {
    'history_v2_id': 'h1',
    'session_id': 's1',
    'message_id': 'm2',
    'messages': '[]',
  });
  await db.insert('task', {
    'task_id': 'tk1',
    'session_id': 's1',
    'message_id': 'm2',
    'status': 'completed',
  });
  await db.insert('agent_run', {
    'agent_run_id': 'ar1',
    'session_id': 's1',
    'agent_id': 'solo_agent',
  });
  await db.insert('server_history_info', {
    'history_id': 'hi1',
    'client_history_id': 'hi0',
    'session_id': 'm2',
    'task_id': 'tk1',
    'agent_run_id': 'ar1',
  });
  await db.insert('core_memory', {
    'user_id': 'uid-old',
    'project_id': 'p-old',
  });
  await db.execute('VACUUM');
  await db.close();

  File(path).writeAsBytesSync(withReserved80(File(path).readAsBytesSync()));
  return path;
}
