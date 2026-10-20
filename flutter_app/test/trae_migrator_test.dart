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

  test('dryRun 不改动目标库', () async {
    final sourcePlain = await buildPlainTraeDb(
      dir: temp,
      name: 'src.db',
      sessions: const [
        FixtureSession(id: 'sess-new', title: '新会话', messages: [('user', 'x')]),
      ],
    );
    final targetPlain = await buildPlainTraeDb(
      dir: temp,
      name: 'dst.db',
      sessions: const [
        FixtureSession(id: 'sess-old', title: '旧会话', messages: [('user', 'y')]),
      ],
    );
    final target = await encrypted(targetPlain, dstKey, 'dst-enc.db');
    final before = File(target).readAsBytesSync();

    final result = await migrator.merge(
      fromPath: sourcePlain,
      dbPath: target,
      dstKey: dstKey,
      dryRun: true,
      requireClientClosed: false,
    );

    expect(result.dryRun, isTrue);
    expect(result.newSessions, 1);
    expect(File(target).readAsBytesSync(), equals(before));
  });
}
