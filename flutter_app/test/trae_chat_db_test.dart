import 'dart:convert';
import 'dart:io';

import 'package:checkin_hub/src/services/sessions/trae_chat_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/trae_fixture.dart';

/// Trae 加密库（SQLCipher v4）的解密与正文解析。
///
/// 用一份按同样格式加密的临时库做夹具，不依赖本机是否装了 Trae。
void main() {
  const keyHex =
      '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
  const sessionId = 'sess-0001';

  late Directory temp;

  setUp(() async {
    sqfliteFfiInit();
    temp = await Directory.systemTemp.createTemp('trae-chat-db-test-');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 忽略。
    }
  });

  Future<String> buildEncryptedDb() async {
    final plainPath = p.join(temp.path, 'plain-source.db');
    final db = await databaseFactoryFfi.openDatabase(
      plainPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.execute(
      'CREATE TABLE chat_message (message_id TEXT PRIMARY KEY, session_id TEXT, '
      'message_role TEXT, message_type TEXT, message_index INTEGER, '
      'created_at INTEGER, updated_at INTEGER, reply_to_message_id TEXT, '
      'deleted_at INTEGER DEFAULT 0, is_archived INTEGER DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE chat_message_general (message_id TEXT, content TEXT, '
      'deleted_at INTEGER DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE chat_message_chat (message_id TEXT, content TEXT, '
      'deleted_at INTEGER DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE chat_message_task (message_id TEXT, content TEXT, '
      'summary TEXT, deleted_at INTEGER DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE history_v2 (session_id TEXT, messages TEXT)',
    );

    await db.insert('chat_message', {
      'message_id': 'm1',
      'session_id': sessionId,
      'message_role': 'user',
      'message_type': 'general',
      'message_index': 1,
      'created_at': 1700000000,
    });
    await db.insert('chat_message_general', {
      'message_id': 'm1',
      'content': '帮我看下磁盘',
    });

    final trace = jsonEncode({
      'task_id': 't1',
      'messages': [
        {
          'plan_item': {
            'reasoning_content': '先看目录大小',
            'tool_call_info': {
              'params': {'description': '统计目录', 'command': 'du -sh /tmp'},
            },
            'content': '先执行 du',
          },
        },
      ],
    });
    await db.insert('chat_message', {
      'message_id': 'm2',
      'session_id': sessionId,
      'message_role': 'assistant',
      'message_type': 'task',
      'message_index': 2,
      'created_at': 1700000001,
    });
    await db.insert('chat_message_task', {'message_id': 'm2', 'content': trace});

    await db.insert('chat_message', {
      'message_id': 'm3',
      'session_id': sessionId,
      'message_role': 'user',
      'message_type': 'general',
      'message_index': 3,
      'created_at': 1700000002,
    });
    await db.insert('chat_message_general', {
      'message_id': 'm3',
      'content': jsonEncode([
        {'text_content': '第二部分'},
      ]),
    });

    await db.insert('history_v2', {
      'session_id': sessionId,
      'messages': jsonEncode([
        {'role': 'assistant', 'content': '磁盘还有 20G 可用', 'created_at': 1700000003},
      ]),
    });
    // VACUUM 重建一遍，页内不留 freeblock（搬页时只挪内容块就够）。
    await db.execute('VACUUM');
    await db.close();

    // SQLCipher 的页可用区是 4016 字节（末尾 80 字节留给 IV/HMAC），
    // 所以夹具也要按同样的页布局重建，否则内容会被 IV 覆盖。
    final source = withReserved80(File(plainPath).readAsBytesSync());
    expect(source.length % 4096, 0, reason: 'SQLite 默认页大小应是 4096');

    final plainReserve = p.join(temp.path, 'plain-reserve.db');
    File(plainReserve).writeAsBytesSync(source);
    final check = await databaseFactoryFfi.openDatabase(
      plainReserve,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final rows = await check.query('chat_message');
    await check.close();
    expect(rows.length, 3, reason: '转了 reserve=80 之后库还得能正常读');

    final encryptedPath = p.join(temp.path, 'database.db');
    File(encryptedPath).writeAsBytesSync(encryptFixture(source, keyHex));
    return encryptedPath;
  }

  test('解密后能读出消息与任务轨迹', () async {
    final path = await buildEncryptedDb();
    final db = await TraeChatDb.open(dbPath: path, key: keyHex);
    addTearDown(db.close);

    final messages = await db.messages(sessionId);
    expect(messages.map((m) => m.role).toList(), [
      'user',
      'assistant',
      'user',
      'assistant',
    ]);
    expect(messages[0].text, '帮我看下磁盘');
    expect(messages[0].createdAt, DateTime.utc(2023, 11, 14, 22, 13, 20));
    expect(messages[1].text, contains('[思考] 先看目录大小'));
    expect(messages[1].text, contains('[工具] 统计目录 — du -sh /tmp'));
    expect(messages[1].text, contains('先执行 du'));
    expect(messages[2].text, '第二部分');
    // history_v2 里的最终回复要补进来。
    expect(messages[3].text, '磁盘还有 20G 可用');
  });

  test('key 不对时抛出 TraeChatException', () async {
    final path = await buildEncryptedDb();
    await expectLater(
      TraeChatDb.open(
        dbPath: path,
        key: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      ),
      throwsA(isA<TraeChatException>()),
    );
  });

  test('没有消息的会话返回空列表', () async {
    final path = await buildEncryptedDb();
    final db = await TraeChatDb.open(dbPath: path, key: keyHex);
    addTearDown(db.close);
    expect(await db.messages('sess-unknown'), isEmpty);
  });
}

