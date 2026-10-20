import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 读取 VS Code 系客户端的 `state.vscdb`（ItemTable）。
///
/// 客户端运行时数据库处于 WAL 模式并被进程占用，直接只读打开容易失败，
/// 所以这里先把主库与 `-wal` / `-shm` 复制到临时目录，再在副本上查询，
/// 读完立即删除，不会改动客户端本身的数据。
class VscdbReader {
  VscdbReader._();

  static bool _ffiReady = false;

  static Future<List<Map<String, Object?>>> readItemTable(
    String path, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    if (!DesktopLike.supported) return const [];
    final file = File(path);
    if (!file.existsSync()) return const [];

    Directory? temp;
    Database? db;
    try {
      temp = await Directory.systemTemp.createTemp('checkin-hub-vscdb-');
      final copy = p.join(temp.path, 'state.vscdb');
      await file.copy(copy);
      for (final suffix in const ['-wal', '-shm']) {
        final side = File('$path$suffix');
        if (!await side.exists()) continue;
        try {
          await side.copy('$copy$suffix');
        } catch (_) {
          // 副本没有 WAL 也能读到主库里的已提交数据。
        }
      }

      if (!_ffiReady) {
        sqfliteFfiInit();
        _ffiReady = true;
      }
      db = await databaseFactoryFfi.openDatabase(
        copy,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      return await db.query(
        'ItemTable',
        columns: const ['key', 'value'],
        where: where,
        whereArgs: whereArgs,
      );
    } catch (_) {
      // 数据库被占用、损坏或不是 SQLite：当作没有数据，界面照常展示其他来源。
      return const [];
    } finally {
      try {
        await db?.close();
      } catch (_) {
        // 忽略
      }
      try {
        await temp?.delete(recursive: true);
      } catch (_) {
        // 忽略
      }
    }
  }
}

/// 只在这些平台上读本机数据库文件。
class DesktopLike {
  DesktopLike._();

  static bool get supported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;
}
