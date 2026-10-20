import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int fixturePageSize = 4096;
const int fixtureReserve = 80;

/// 把普通 SQLite 页布局（内容贴着页尾）转成 SQLCipher 的 80 字节保留布局：
/// 内容整体前移 80 字节，同步修正内容区起点、cell pointer、freeblock 与文件头的保留字节数。
Uint8List withReserved80(Uint8List source) {
  const pageSize = fixturePageSize;
  const reserve = fixtureReserve;
  final out = Uint8List(source.length);
  for (var pageStart = 0; pageStart < source.length; pageStart += pageSize) {
    final page = Uint8List.sublistView(source, pageStart, pageStart + pageSize);
    out.setRange(pageStart, pageStart + pageSize, page);
    // 第 1 页前面还有 100 字节的文件头，b-tree 头从偏移 100 开始。
    final at = pageStart == 0 ? 100 : 0;
    final type = page[at];
    if (type != 2 && type != 5 && type != 10 && type != 13) continue;
    final interior = type == 2 || type == 5;
    final headerSize = at + (interior ? 12 : 8);
    final firstFreeBlock = (page[at + 1] << 8) | page[at + 2];

    final cells = (page[at + 3] << 8) | page[at + 4];
    final contentStart = (page[at + 5] << 8) | page[at + 6];
    if (contentStart == 0) continue; // 空页
    final contentLength = pageSize - contentStart;
    if (contentLength > pageSize - reserve) {
      throw StateError('夹具太大，单页内容放不进 4016 字节');
    }

    final newStart = contentStart - reserve;
    out.setRange(
      pageStart + pageSize - reserve - contentLength,
      pageStart + pageSize - reserve,
      page.sublist(contentStart),
    );
    out.setRange(
      pageStart + pageSize - reserve,
      pageStart + pageSize,
      List<int>.filled(reserve, 0),
    );
    out[pageStart + at + 5] = newStart >> 8;
    out[pageStart + at + 6] = newStart & 0xff;
    for (var i = 0; i < cells; i++) {
      final sourceAt = headerSize + i * 2;
      final moved = ((page[sourceAt] << 8) | page[sourceAt + 1]) - reserve;
      if (moved < 0) throw StateError('cell 偏移异常');
      out[pageStart + sourceAt] = moved >> 8;
      out[pageStart + sourceAt + 1] = moved & 0xff;
    }
    // freeblock 也在内容区里，随整块一起前移，next 指针要同步改。
    if (firstFreeBlock != 0) {
      out[pageStart + at + 1] = (firstFreeBlock - reserve) >> 8;
      out[pageStart + at + 2] = (firstFreeBlock - reserve) & 0xff;
      var free = firstFreeBlock;
      while (free != 0) {
        final next = (page[free] << 8) | page[free + 1];
        final size = (page[free + 2] << 8) | page[free + 3];
        if (size == 0) throw StateError('freeblock 结构异常');
        final moved = free - reserve;
        out[pageStart + moved] = next == 0 ? 0 : (next - reserve) >> 8;
        out[pageStart + moved + 1] = next == 0 ? 0 : (next - reserve) & 0xff;
        free = next;
      }
    }
    if (pageStart == 0) out[20] = reserve;
  }
  return out;
}

/// 按 SQLCipher v4 页格式加密整库（独立实现，不复用生产代码，避免自证）。
Uint8List encryptFixture(Uint8List plain, String keyHex, {Uint8List? salt}) {
  final key = _hex(keyHex);
  final random = Random.secure();
  final out = Uint8List(plain.length);
  final realSalt =
      salt ??
      Uint8List.fromList(List<int>.generate(16, (_) => random.nextInt(256)));
  for (var offset = 0; offset < plain.length; offset += fixturePageSize) {
    final pgno = offset ~/ fixturePageSize + 1;
    final iv = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final from = pgno == 1 ? 16 : 0;
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    for (var i = from; i < 4016; i += 16) {
      cipher.processBlock(plain, offset + i, out, offset + i);
    }
    out.setRange(offset + 4016, offset + 4032, iv);
    if (pgno == 1) out.setRange(offset, offset + 16, realSalt);
  }
  return out;
}

/// 一条会话的夹具数据。
class FixtureSession {
  const FixtureSession({
    required this.id,
    required this.title,
    required this.messages,
    this.projectId = 'proj-1',
  });

  final String id;
  final String title;

  /// (role, text)
  final List<(String, String)> messages;
  final String projectId;
}

/// 建一个带 reserve=80 的明文库（SQLCipher 布局），返回明文路径。
Future<String> buildPlainTraeDb({
  required Directory dir,
  required String name,
  required List<FixtureSession> sessions,
}) async {
  final path = p.join(dir.path, name);
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute(
    'CREATE TABLE chat_session (session_id TEXT PRIMARY KEY, session_title TEXT, '
    'project_id TEXT, created_at INTEGER, updated_at INTEGER, deleted_at INTEGER DEFAULT 0)',
  );
  await db.execute(
    'CREATE TABLE chat_message (message_id TEXT PRIMARY KEY, session_id TEXT, '
    'message_role TEXT, message_type TEXT, message_index INTEGER, created_at INTEGER, '
    'updated_at INTEGER, reply_to_message_id TEXT, deleted_at INTEGER DEFAULT 0, '
    'is_archived INTEGER DEFAULT 0)',
  );
  await db.execute(
    'CREATE TABLE chat_message_general (message_id TEXT, content TEXT, '
    'deleted_at INTEGER DEFAULT 0)',
  );
  await db.execute('CREATE TABLE history_v2 (session_id TEXT, messages TEXT)');
  await db.execute(
    'CREATE TABLE project (project_id TEXT PRIMARY KEY, name TEXT)',
  );
  await db.execute(
    'CREATE TABLE session_project (session_id TEXT, project_id TEXT)',
  );

  await db.insert(
    'project',
    {'project_id': 'proj-1', 'name': '默认项目'},
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
  for (final session in sessions) {
    await db.insert('chat_session', {
      'session_id': session.id,
      'session_title': session.title,
      'project_id': session.projectId,
      'created_at': 1700000000,
      'updated_at': 1700000000,
    });
    await db.insert('session_project', {
      'session_id': session.id,
      'project_id': session.projectId,
    });
    for (var i = 0; i < session.messages.length; i++) {
      final (role, text) = session.messages[i];
      final messageId = '${session.id}-m$i';
      await db.insert('chat_message', {
        'message_id': messageId,
        'session_id': session.id,
        'message_role': role,
        'message_type': 'general',
        'message_index': i + 1,
        'created_at': 1700000000 + i,
      });
      await db.insert('chat_message_general', {
        'message_id': messageId,
        'content': text,
      });
    }
  }
  await db.execute('VACUUM');
  await db.close();

  final source = File(path).readAsBytesSync();
  final reserved = withReserved80(source);
  File(path).writeAsBytesSync(reserved);
  return path;
}

Uint8List _hex(String value) {
  final bytes = Uint8List(value.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
