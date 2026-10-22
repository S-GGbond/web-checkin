import 'dart:convert';
import 'dart:io';

import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/models/chat_session.dart';
import 'package:checkin_hub/src/services/sessions/session_service.dart';
import 'package:checkin_hub/src/services/sessions/trae_chat_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 会话读取与跨账号复制（用临时目录模拟客户端数据目录）。
Future<List<TraeSessionInfo>> _noTraeIndex() async => const [];

Future<List<ChatMessage>> _noTraeMessages(ChatSession session) async =>
    const [];

void main() {
  late Directory temp;
  // Trae 正文要读本机加密库，单测里替换掉，保证不依赖运行环境。
  const service = SessionService(
    traeReader: _noTraeMessages,
    traeIndex: _noTraeIndex,
  );
  const sourceUid = 'uid-source';
  const targetUid = 'uid-target';
  const workspaceId = 'ws-000000000000000000000001';
  const sessionId = 'session-00000000000000000001';

  Future<void> writeJson(String path, Object value) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(value is String ? value : jsonEncode(value));
  }

  /// 生成一个最小的 `state.vscdb` / `codebuddy-sessions.vscdb`（ItemTable 两列）。
  Future<void> writeVscdb(String path, Map<String, String> rows) async {
    await Directory(p.dirname(path)).create(recursive: true);
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT)',
    );
    for (final entry in rows.entries) {
      await db.insert('ItemTable', {
        'key': entry.key,
        'value': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await db.close();
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('checkin-session-test-');
    final root = SessionService.accountRoot(temp.path, sourceUid);
    final sessionDir = p.join(root, 'history', workspaceId, sessionId);
    await writeJson(p.join(root, 'history', workspaceId, 'index.json'), {
      'conversations': [
        {
          'id': sessionId,
          'type': 'chat',
          'name': '测试会话',
          'createdAt': '2026-10-13T01:25:35.628Z',
          'lastMessageAt': '2026-10-13T02:25:35.628Z',
        },
      ],
      'current': sessionId,
    });
    await writeJson(p.join(sessionDir, 'index.json'), {
      'messages': [
        {'id': 'm1', 'type': 'text', 'role': 'user'},
        {'id': 'm2', 'type': 'text', 'role': 'assistant'},
        {'id': 'm3', 'type': 'text', 'role': 'tool'},
      ],
      'requests': [],
    });
    await writeJson(p.join(sessionDir, 'messages', 'm1.json'), {
      'id': 'm1',
      'role': 'user',
      'message': '帮我看看这个报错',
      'createdAt': '2026-10-13T01:26:00.000Z',
    });
    // message 是 JSON 字符串，正文在 content 分片里（客户端真实格式）
    await writeJson(p.join(sessionDir, 'messages', 'm2.json'), {
      'id': 'm2',
      'role': 'assistant',
      'message': jsonEncode({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': '这个报错是因为端口被占用。'},
        ],
      }),
    });
    await writeJson(p.join(sessionDir, 'messages', 'm3.json'), {
      'id': 'm3',
      'role': 'tool',
      'message': '{"role":"tool","content":[]}',
    });
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('列出会话并统计消息数', () async {
    final sessions = await service.listSessions(
      PlatformKind.workbuddy,
      sourceUid,
      dataRoot: temp.path,
    );
    expect(sessions, hasLength(1));
    expect(sessions.single.title, '测试会话');
    expect(sessions.single.workspaceId, workspaceId);
    expect(sessions.single.messageCount, 2);
    expect(
      sessions.single.updatedAt,
      DateTime.parse('2026-10-13T02:25:35.628Z'),
    );
  });

  test('空会话与未命名会话不进入列表', () async {
    final root = SessionService.accountRoot(temp.path, sourceUid);
    const emptyWs = 'ws-empty-00000000000000000001';
    const emptyId = 'session-empty-0000000000001';
    await writeJson(p.join(root, 'history', emptyWs, 'index.json'), {
      'conversations': [
        {
          'id': emptyId,
          'type': 'chat',
          'name': '未命名会话',
          'createdAt': '2026-10-13T00:00:00.000Z',
        },
      ],
      'current': emptyId,
    });
    await writeJson(p.join(root, 'history', emptyWs, emptyId, 'index.json'), {
      'messages': [],
      'requests': [],
    });

    final sessions = await service.listSessions(
      PlatformKind.workbuddy,
      sourceUid,
      dataRoot: temp.path,
    );
    expect(sessions, hasLength(1));
    expect(sessions.single.sessionId, sessionId);
  });

  test('读取消息时跳过工具消息并解析 JSON 正文', () async {
    final sessions = await service.listSessions(
      PlatformKind.workbuddy,
      sourceUid,
      dataRoot: temp.path,
    );
    final messages = await service.readMessages(
      sessions.single,
      dataRoot: temp.path,
    );
    expect(messages, hasLength(2));
    expect(messages.first.role, 'user');
    expect(messages.first.text, '帮我看看这个报错');
    expect(messages.last.role, 'assistant');
    expect(messages.last.text, '这个报错是因为端口被占用。');
  });

  test('复制到另一个账号：新会话 id、保留标题、写入目标索引', () async {
    final sessions = await service.listSessions(
      PlatformKind.workbuddy,
      sourceUid,
      dataRoot: temp.path,
    );
    final copied = await service.copySessions(
      sessions: sessions,
      targetUid: targetUid,
      dataRoot: temp.path,
    );
    expect(copied, 1);

    final targetSessions = await service.listSessions(
      PlatformKind.workbuddy,
      targetUid,
      dataRoot: temp.path,
    );
    expect(targetSessions, hasLength(1));
    expect(targetSessions.single.title, '测试会话');
    expect(targetSessions.single.sessionId, isNot(sessionId));
    expect(targetSessions.single.sessionId, hasLength(32));
    expect(targetSessions.single.messageCount, 2);

    final messages = await service.readMessages(
      targetSessions.single,
      dataRoot: temp.path,
    );
    expect(messages.map((message) => message.text), contains('这个报错是因为端口被占用。'));

    final indexFile = File(
      p.join(
        SessionService.accountRoot(temp.path, targetUid),
        'history',
        workspaceId,
        'index.json',
      ),
    );
    final index =
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
    expect((index['conversations'] as List), hasLength(1));
    expect(index['current'], targetSessions.single.sessionId);
  });

  test('重复同步生成不同 id，不会覆盖已有会话', () async {
    final sessions = await service.listSessions(
      PlatformKind.workbuddy,
      sourceUid,
      dataRoot: temp.path,
    );
    await service.copySessions(
      sessions: sessions,
      targetUid: targetUid,
      dataRoot: temp.path,
    );
    await service.copySessions(
      sessions: sessions,
      targetUid: targetUid,
      dataRoot: temp.path,
    );
    final targetSessions = await service.listSessions(
      PlatformKind.workbuddy,
      targetUid,
      dataRoot: temp.path,
    );
    expect(targetSessions, hasLength(2));
    expect(
      targetSessions.map((session) => session.sessionId).toSet(),
      hasLength(2),
    );
  });

  test('目标与来源相同时拒绝', () async {
    final sessions = await service.listSessions(
      PlatformKind.workbuddy,
      sourceUid,
      dataRoot: temp.path,
    );
    await expectLater(
      service.copySessions(
        sessions: sessions,
        targetUid: sourceUid,
        dataRoot: temp.path,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('桌面端元数据补充标题与状态；只有元数据、没有消息的会话不列出', () async {
    final db = p.join(temp.path, 'CodeBuddy CN', 'codebuddy-sessions.vscdb');
    await writeVscdb(db, {
      'session:$sessionId': jsonEncode({
        'conversationId': sessionId,
        'title': '元数据标题',
        'status': 'idle',
        'cwd': '/home/chen/Project/web-checkin',
        'updatedAt': 1792378342972,
      }),
      'session:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa': jsonEncode({
        'title': '只有元数据的会话',
        'createdAt': 1792378000000,
        'updatedAt': 1792378342972,
      }),
    });

    final result = await service.scan(
      workbuddyRoots: [temp.path],
      codebuddyVscdbs: [db],
      cliRoot: '',
      traeRoots: const [],
      scanQoder: false,
      scanWorkbuddyApp: false,
    );

    expect(result.workbuddyMetaRows, 2);
    final merged = result.sessions.firstWhere(
      (item) => item.sessionId == sessionId,
    );
    expect(merged.title, '元数据标题');
    expect(merged.status, 'idle');
    expect(merged.copyable, isTrue);

    // 0 条消息的会话没有内容可看，直接不进列表。
    expect(
      result.sessions.where(
        (item) => item.sessionId == 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      isEmpty,
    );
  });

  test('CLI：从 jsonl 读取标题、项目、消息数并解析正文', () async {
    final cliRoot = p.join(temp.path, 'cli');
    final file = File(
      p.join(
        cliRoot,
        'home-chen-Project',
        '01a1520f-e16b-78f0-a71d-e57030f36ae3.jsonl',
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      [
        jsonEncode({
          'type': 'message',
          'role': 'user',
          'content': [
            {
              'type': 'input_text',
              'text':
                  '<environment>\nOS Version: Linux\n</environment>\n帮我看看这个报错',
            },
          ],
          'cwd': '/home/chen/Project/web-checkin',
          'timestamp': 1792378134970,
        }),
        jsonEncode({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': '这个报错是因为端口被占用。'},
          ],
          'timestamp': 1792378135970,
        }),
        jsonEncode({'type': 'tool', 'name': 'shell'}),
      ].join('\n'),
    );

    final result = await service.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: cliRoot,
      traeRoots: const [],
      scanQoder: false,
      scanWorkbuddyApp: false,
    );

    expect(result.workbuddyCliSessions, 1);
    final session = result.sessions.single;
    expect(session.source, SessionSource.workbuddyCli);
    expect(session.title, '帮我看看这个报错');
    expect(session.project, '/home/chen/Project/web-checkin');
    // 只数用户 / AI 消息，工具事件不算。
    expect(session.messageCount, 2);
    expect(session.copyable, isFalse);

    final messages = await service.readMessages(session);
    expect(messages, hasLength(2));
    expect(messages.first.role, 'user');
    expect(messages.first.text, contains('帮我看看这个报错'));
    expect(messages.last.text, '这个报错是因为端口被占用。');
  });

  test('CLI 会话迁到目标账号：写成桌面端会话目录并可读回', () async {
    final cliRoot = p.join(temp.path, 'cli-merge');
    final file = File(
      p.join(
        cliRoot,
        'home-chen-Project',
        '01a1520f-e16b-78f0-a71d-e57030f36ae3.jsonl',
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      [
        jsonEncode({
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': '帮我看看这个报错'},
          ],
          'cwd': '/home/chen/Project/web-checkin',
          'timestamp': 1792378134970,
        }),
        jsonEncode({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': '这个报错是因为端口被占用。'},
          ],
          'timestamp': 1792378135970,
        }),
      ].join('\n'),
    );

    final scan = await service.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: cliRoot,
      traeRoots: const [],
      scanQoder: false,
      scanWorkbuddyApp: false,
    );
    final session = scan.sessions.single;
    expect(session.accountMigratable, isTrue);

    // 元数据库：客户端用它按 userId 归属会话。
    final metaDb = p.join(temp.path, 'meta', 'codebuddy-sessions.vscdb');
    final copied = await service.copySessions(
      sessions: [session],
      targetUid: targetUid,
      dataRoot: temp.path,
      metaDbPath: metaDb,
    );
    expect(copied, 1);

    // 工作区 id 必须是客户端那套 md5(工作区路径)。
    expect(
      SessionService.workspaceIdForPath('/home/chen/Project/web-checkin'),
      '8c4fd0af896d248be28035d688857e8d',
    );
    final workspaceDir = Directory(
      p.join(
        SessionService.accountRoot(temp.path, targetUid),
        'history',
        '8c4fd0af896d248be28035d688857e8d',
      ),
    );
    expect(workspaceDir.existsSync(), isTrue);

    final meta = await databaseFactoryFfi.openDatabase(
      metaDb,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final rows = await meta.query('ItemTable');
      expect(rows, hasLength(1));
      expect(rows.single['key'], startsWith('session:'));
      final value =
          jsonDecode(rows.single['value']! as String) as Map<String, dynamic>;
      expect(value['userId'], targetUid);
      expect(value['title'], '帮我看看这个报错');
      expect(value['cwd'], '/home/chen/Project/web-checkin');
    } finally {
      await meta.close();
    }

    final targetSessions = await service.listSessions(
      PlatformKind.workbuddy,
      targetUid,
      dataRoot: temp.path,
    );
    expect(targetSessions, hasLength(1));
    expect(targetSessions.single.source, SessionSource.workbuddyDesktop);
    expect(targetSessions.single.title, '帮我看看这个报错');
    expect(targetSessions.single.messageCount, 2);

    final messages = await service.readMessages(
      targetSessions.single,
      dataRoot: temp.path,
    );
    expect(messages, hasLength(2));
    expect(messages.first.role, 'user');
    expect(messages.last.text, '这个报错是因为端口被占用。');
  });

  test('WorkBuddy 客户端会话：读 workbuddy.db，迁移改 user_id', () async {
    final root = p.join(temp.path, 'wb');
    final dbPath = p.join(root, 'workbuddy.db');
    await Directory(p.join(root, 'projects', 'home-chen-Project-demo')).create(
      recursive: true,
    );
    await File(
      p.join(
        root,
        'projects',
        'home-chen-Project-demo',
        'sess-wb.jsonl',
      ),
    ).writeAsString(
      [
        jsonEncode({
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'WorkBuddy 里的问题'},
          ],
          'timestamp': 1792378134970,
        }),
        jsonEncode({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'WorkBuddy 里的回答'},
          ],
          'timestamp': 1792378135970,
        }),
      ].join('\n'),
    );

    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.execute(
      'CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, user_id TEXT, '
      'title TEXT, custom_title TEXT, status TEXT, created_at INTEGER, '
      'updated_at INTEGER, last_activity_at INTEGER, deleted_at INTEGER, '
      'model TEXT)',
    );
    await db.insert('sessions', {
      'id': 'sess-wb',
      'cwd': '/home/chen/Project/demo',
      'user_id': 'uid-a',
      'title': 'WorkBuddy 里的问题',
      'status': 'completed',
      'created_at': 1792378134970,
      'updated_at': 1792378135970,
      'last_activity_at': 1792378135970,
    });
    await db.insert('sessions', {
      'id': 'sess-empty',
      'cwd': '/home/chen/Project/demo',
      'user_id': 'uid-a',
      'title': '没有正文的占位',
      'status': 'completed',
      'created_at': 1792378134970,
      'updated_at': 1792378135970,
    });
    await db.close();

    final scan = await service.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: '/nonexistent',
      traeRoots: const [],
      scanQoder: false,
      appRoot: root,
    );
    final session = scan.sessions.single;
    expect(session.source, SessionSource.workbuddyApp);
    expect(session.accountUid, 'uid-a');
    expect(session.title, 'WorkBuddy 里的问题');
    expect(session.messageCount, 2);
    // 没有 jsonl 正文的占位会话不进列表。
    expect(
      scan.sessions.where((item) => item.sessionId == 'sess-empty'),
      isEmpty,
    );

    final moved = await service.copySessions(
      sessions: [session],
      targetUid: 'uid-b',
      appDbPath: dbPath,
    );
    expect(moved, 1);

    final rescanned = await service.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: '/nonexistent',
      traeRoots: const [],
      scanQoder: false,
      appRoot: root,
    );
    expect(rescanned.sessions.single.accountUid, 'uid-b');
  });

  test('Trae：聚合状态库、快照与日志', () async {
    final root = p.join(temp.path, 'Trae CN');
    const id = '6acf467e9ffe324bf354afd6';
    const userId = '2464446851333947';

    await writeVscdb(p.join(root, 'User', 'globalStorage', 'state.vscdb'), {
      'ai-chat.chatQueryCompletion.v1.$id': jsonEncode({
        'savedAt': 1792378342972,
        'messagesLength': 20,
        'response': {
          'modelName': 'claude-sonnet-4.5',
          'result': [
            {'text': '请重新生成图片'},
          ],
        },
      }),
      '$userId:draft:session:$id:code': jsonEncode({
        'updatedAt': 1792378342972,
      }),
    });

    await Directory(
      p.join(root, 'ModularData', 'ai-agent', 'snapshot', id),
    ).create(recursive: true);
    final log = File(
      p.join(root, 'logs', '20261019T101325', 'window-1', 'renderer.log'),
    );
    await log.parent.create(recursive: true);
    await log.writeAsString(
      'session_updated {"chat_session_id":"$id","title":"列出 Trae 会话列表脚本",'
      '"user_id":"$userId","updated_at":1792378342972}\n',
    );

    // 会话库索引里保留这条会话，状态库 / 备注仍然由它们自己补。
    final indexed = SessionService(
      traeReader: _noTraeMessages,
      traeIndex: () async => const [
        TraeSessionInfo(
          sessionId: id,
          projectId: 'p1',
          userId: userId,
          title: '',
          projectPath: '/w/x',
          createdAt: 1,
          updatedAt: 1792378342,
          messages: 0,
        ),
      ],
    );
    final result = await indexed.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: '',
      traeRoots: [root],
      scanQoder: false,
      scanWorkbuddyApp: false,
    );

    expect(result.traeCount, 1);
    final session = result.sessions.single;
    expect(session.provider, PlatformKind.trae);
    expect(session.accountUid, userId);
    expect(session.title, '列出 Trae 会话列表脚本');
    expect(session.model, 'claude-sonnet-4.5');
    expect(session.preview, '请重新生成图片');
    expect(session.messageCount, 20);
    expect(session.origin, containsAll(['vscdb', 'snapshot', 'log']));
    expect(session.copyable, isFalse);
    expect(await service.readMessages(session), isEmpty);
  });
  test('Trae：会话库补全归属，未绑定的会话按项目账号归档', () async {
    final root = p.join(temp.path, 'Trae CN');
    const legacyId = '6acf467e9ffe324bf354afd6';
    const dbOnlyId = '6ad1d02094bafc7912aa8179';

    // 状态库只留了一条旧账号的 draft 键；真实归属以会话库的 project.user_id 为准。
    await writeVscdb(p.join(root, 'User', 'globalStorage', 'state.vscdb'), {
      '1729960883004504:draft:session:$legacyId:code': jsonEncode({
        'updatedAt': 1792378342972,
      }),
    });

    final scoped = SessionService(
      traeReader: _noTraeMessages,
      traeIndex: () async => const [
        TraeSessionInfo(
          sessionId: legacyId,
          projectId: 'p1',
          userId: 'uid-old',
          title: '状态库里的旧账号',
          projectPath: '/w/a',
          createdAt: 1,
          updatedAt: 1792378342,
          messages: 3,
        ),
        TraeSessionInfo(
          sessionId: dbOnlyId,
          projectId: 'p2',
          userId: 'uid-new',
          title: '只在会话库里',
          projectPath: '/w/b',
          createdAt: 1,
          updatedAt: 1792378400,
          messages: 5,
        ),
      ],
    );

    final result = await scoped.scan(
      workbuddyRoots: const [],
      codebuddyVscdbs: const [],
      cliRoot: '',
      traeRoots: [root],
      scanQoder: false,
      scanWorkbuddyApp: false,
    );

    expect(result.traeCount, 2);
    final legacy = result.sessions.firstWhere((s) => s.sessionId == legacyId);
    expect(legacy.accountUid, 'uid-old');
    expect(legacy.project, '/w/a');

    final dbOnly = result.sessions.firstWhere((s) => s.sessionId == dbOnlyId);
    expect(dbOnly.accountUid, 'uid-new');
    expect(dbOnly.title, '只在会话库里');
    expect(dbOnly.messageCount, 5);
    expect(dbOnly.project, '/w/b');
    expect(dbOnly.origin, contains('db'));
    // 没有任何会话是「未关联账号」。
    expect(
      result.sessions.where((s) => s.accountUid.isEmpty),
      isEmpty,
    );
  });

}
