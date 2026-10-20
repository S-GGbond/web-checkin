import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/account.dart';
import '../../util/app_paths.dart';
import '../desktop/desktop_client.dart';
import 'trae_chat_db.dart';
import 'trae_db_cipher.dart';
import 'trae_db_key.dart';

/// 会话迁移失败（找不到库 / 拿不到密钥 / 客户端在运行 / 校验不过）。
class TraeMigrationException implements Exception {
  const TraeMigrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 导出的明文迁移包。
class TraePackResult {
  const TraePackResult({
    required this.path,
    required this.sessions,
    required this.sizeBytes,
  });

  final String path;
  final int sessions;
  final int sizeBytes;
}

/// 一次合并的结果（[tables] 为 表名 → (实际写入, 源命中)）。
class TraeMergeResult {
  const TraeMergeResult({
    required this.sourceSessions,
    required this.newSessions,
    required this.tables,
    required this.skipped,
    required this.dryRun,
    this.backupPath,
  });

  final int sourceSessions;
  final int newSessions;
  final Map<String, (int, int)> tables;
  final List<String> skipped;
  final bool dryRun;
  final String? backupPath;

  int get rows => tables.values.fold(0, (sum, entry) => sum + entry.$1);
}

/// Trae 会话迁移：源机导出明文包，目标机增量合并回加密库。
///
/// 与 db-migrate.mjs 同一套流程：
/// 1. pack：抓 key → 只读快照解密 → 另存明文包（敏感，传完即删）
/// 2. merge：确认客户端已退出 → 解密目标库 → 按会话图合并（整会话粒度，重复跳过）
///    → 完整性校验 → 用目标 key 重新加密并自校验 → 备份 + 原子替换
///
/// 合并只动临时明文库，任何一步失败都不会写入客户端原库。
class TraeMigrator {
  const TraeMigrator();

  /// 导出明文迁移包；[outputPath] 不传则写到用户主目录。
  /// [sessionIds] 只导出这些会话（会话页勾选导出）；不传则整库导出。
  Future<TraePackResult> pack({
    String? dbPath,
    String? outputPath,
    String? key,
    Set<String>? sessionIds,
    void Function(String message)? log,
  }) async {
    final source = dbPath ?? TraeChatDb.defaultDatabasePath();
    if (source == null) {
      throw const TraeMigrationException('没有找到 Trae 客户端的会话数据库');
    }
    if (!await File(source).exists()) {
      throw TraeMigrationException('会话数据库不存在：$source');
    }
    final secret = await TraeDbKey.resolve(
      dbPath: source,
      manual: key,
      validate: (candidate) => TraeDbCipher.validateKey(candidate, source),
      log: log,
    );
    if (secret == null) {
      throw const TraeMigrationException(
        '未能取得 Trae 会话库密钥（客户端未运行；也可用 TRAE_DB_KEY 手动指定）',
      );
    }

    final work = await Directory.systemTemp.createTemp('checkin-hub-pack-');
    try {
      final plainPath = await TraeChatDb.decryptToPlain(secret, source, work);
      final db = await TraeChatDb.openPlain(
        plainPath,
        readOnly: sessionIds == null,
      );
      int sessions;
      try {
        if (sessionIds != null) {
          await _keepOnlySelected(db, sessionIds);
        }
        final rows = await db.rawQuery(
          'SELECT count(*) AS n FROM chat_session WHERE deleted_at = 0',
        );
        sessions = (rows.first['n'] as int?) ?? 0;
      } finally {
        await db.close();
      }

      final out = outputPath ?? _defaultPackPath();
      final file = File(out);
      await file.parent.create(recursive: true);
      await File(plainPath).copy(out);
      return TraePackResult(
        path: out,
        sessions: sessions,
        sizeBytes: await file.length(),
      );
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {
        // 忽略。
      }
    }
  }

  /// 把 [fromPath]（明文包，或带 [srcKey] 的加密库）里的新会话合并进目标库。
  ///
  /// [dryRun] 只做合并并校验，不写回目标库。
  Future<TraeMergeResult> merge({
    required String fromPath,
    String? dbPath,
    String? srcKey,
    String? dstKey,
    bool dryRun = false,
    bool requireClientClosed = true,
    void Function(String message)? log,
  }) async {
    final target = dbPath ?? TraeChatDb.defaultDatabasePath();
    if (target == null) {
      throw const TraeMigrationException('没有找到 Trae 客户端的会话数据库');
    }
    if (!await File(target).exists()) {
      throw TraeMigrationException('目标会话库不存在：$target');
    }
    if (!await File(fromPath).exists()) {
      throw TraeMigrationException('源文件不存在：$fromPath');
    }
    if (requireClientClosed) {
      final pids = await DesktopClient.runningPids(PlatformKind.trae);
      if (pids.isNotEmpty) {
        throw TraeMigrationException(
          'Trae 正在运行（pid ${pids.join(", ")}），请先完全退出再合并，否则写入会被客户端覆盖',
        );
      }
    }

    final targetKey =
        dstKey ??
        await TraeDbKey.resolve(
          dbPath: target,
          validate: (candidate) =>
              TraeDbCipher.validateKey(candidate, target),
          log: log,
        );
    if (targetKey == null) {
      throw const TraeMigrationException('未能取得目标库密钥');
    }

    final work = await Directory.systemTemp.createTemp('checkin-hub-merge-');
    Database? db;
    try {
      final packPath = await _resolvePack(fromPath, srcKey, work, log);
      final dstPlain = await TraeChatDb.decryptToPlain(
        targetKey,
        target,
        await Directory(p.join(work.path, 'dst')).create(recursive: true),
      );

      db = await TraeChatDb.openPlain(dstPlain, readOnly: false);
      await db.execute('PRAGMA journal_mode = DELETE');
      await db.execute("ATTACH DATABASE '${_quote(packPath)}' AS src");

      final result = await _mergeInto(db);
      await db.execute('DETACH DATABASE src');

      await db.execute('PRAGMA journal_mode = DELETE');
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      final verdict = integrity.isEmpty
          ? ''
          : integrity.first.values.first?.toString() ?? '';
      if (verdict != 'ok') {
        throw TraeMigrationException('合并后完整性校验失败：$verdict（目标库未改动）');
      }
      await db.close();
      db = null;

      if (result.newSessions == 0 || dryRun) {
        return TraeMergeResult(
          sourceSessions: result.sourceSessions,
          newSessions: result.newSessions,
          tables: result.tables,
          skipped: result.skipped,
          dryRun: dryRun,
        );
      }

      final backup = await _writeBack(target, dstPlain, targetKey);
      return TraeMergeResult(
        sourceSessions: result.sourceSessions,
        newSessions: result.newSessions,
        tables: result.tables,
        skipped: result.skipped,
        dryRun: false,
        backupPath: backup,
      );
    } finally {
      try {
        await db?.close();
      } catch (_) {
        // 忽略。
      }
      try {
        await work.delete(recursive: true);
      } catch (_) {
        // 忽略。
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 导出裁剪
  // ---------------------------------------------------------------------------

  /// 只导出选中会话时，把明文快照裁成只含这些会话，避免把整库带出去。
  Future<void> _keepOnlySelected(Database db, Set<String> ids) async {
    if (ids.isEmpty) {
      throw const TraeMigrationException('没有选中任何会话');
    }
    final keep = _inSet(ids);
    final messages = await _ids(
      db,
      'SELECT message_id AS v FROM chat_message WHERE session_id IN ($keep)',
    );
    final turns = await _ids(
      db,
      'SELECT turn_id AS v FROM chat_turn WHERE session_id IN ($keep)',
    );
    final runs = await _ids(
      db,
      'SELECT agent_run_id AS v FROM agent_run WHERE session_id IN ($keep)',
    );
    final requirements = await _ids(
      db,
      'SELECT requirement_id AS v FROM chat_turn WHERE session_id IN ($keep)',
    );
    final tasks = await _ids(
      db,
      'SELECT id AS v FROM task WHERE session_id IN ($keep)',
    );
    final projects = await _ids(
      db,
      'SELECT project_id AS v FROM chat_session WHERE session_id IN ($keep)',
    );
    projects.addAll(
      await _ids(
        db,
        'SELECT project_id AS v FROM session_project WHERE session_id IN ($keep)',
      ),
    );
    final todos = await _ids(
      db,
      'SELECT DISTINCT todo_list_id AS v FROM history_todo_list '
      'WHERE message_id IN (${_inSet(messages)})',
    );

    final tables = await _tables(db, 'main');
    final fts = tables
        .where((table) => table.sql.toLowerCase().contains('using fts'))
        .map((table) => table.name)
        .toList();

    for (final table in tables) {
      if (table.name == 'sqlite_sequence') continue;
      // FTS 虚表与其影子表保持原样：直接删影子表会弄坏索引，导入时也只按链接列取行。
      if (fts.any((name) => table.name.startsWith('${name}_'))) continue;
      if (fts.contains(table.name)) continue;

      final info = await _columns(db, table.name, 'main');
      final rules = _linkRules(
        table.name,
        info.map((c) => c.name).toList(),
        sessions: ids,
        messages: messages,
        turns: turns,
        runs: runs,
        requirements: requirements,
        tasks: tasks,
        projects: projects,
        todos: todos,
      );
      try {
        if (rules.isEmpty) {
          // 没有会话关联列的表（缓存/配置）对迁移没有意义，整表清空。
          await db.execute('DELETE FROM "${_quoteIdent(table.name)}"');
          continue;
        }
        final keepExpr = rules
            .map((rule) => '"${_quoteIdent(rule.$1)}" IN (${_inSet(rule.$2)})')
            .join(' OR ');
        await db.execute(
          'DELETE FROM "${_quoteIdent(table.name)}" '
          'WHERE (CASE WHEN ($keepExpr) THEN 0 ELSE 1 END) = 1',
        );
      } catch (_) {
        // 个别表结构特殊（虚拟表/只读表），跳过即可。
      }
    }

    // 收缩文件：否则导出包里仍带着已删除页。
    await db.execute('VACUUM');
  }

  // ---------------------------------------------------------------------------
  // 合并
  // ---------------------------------------------------------------------------

  /// 源文件可以是明文包（SQLite 头）或加密库（需要 [srcKey]）。
  Future<String> _resolvePack(
    String fromPath,
    String? srcKey,
    Directory work,
    void Function(String message)? log,
  ) async {
    final isPlain = _hasMagic(await _head(fromPath, 16));
    if (isPlain) {
      final check = await TraeChatDb.openPlain(fromPath);
      try {
        final rows = await check.rawQuery('PRAGMA integrity_check');
        final verdict = rows.isEmpty
            ? ''
            : rows.first.values.first?.toString() ?? '';
        if (verdict != 'ok') {
          throw TraeMigrationException('明文包完整性校验失败：$verdict');
        }
      } finally {
        await check.close();
      }
      return fromPath;
    }

    if (srcKey == null) {
      throw const TraeMigrationException(
        '源文件是加密库，需要提供源机密钥（源机执行「导出密钥」或设置 TRAE_DB_KEY）',
      );
    }
    if (!TraeDbCipher.validateKey(srcKey, fromPath)) {
      throw const TraeMigrationException('源机密钥解不开源库第 1 页');
    }
    log?.call('源加密库先解密成明文再合并');
    return TraeChatDb.decryptToPlain(
      srcKey,
      fromPath,
      await Directory(p.join(work.path, 'src')).create(recursive: true),
    );
  }

  Future<TraeMergeResult> _mergeInto(Database db) async {
    final sourceSessions = await _count(db, 'src.chat_session');
    final rows = await db.rawQuery(
      'SELECT s.session_id FROM src.chat_session s '
      'WHERE s.deleted_at = 0 AND NOT EXISTS '
      '(SELECT 1 FROM main.chat_session m WHERE m.session_id = s.session_id)',
    );
    final sessions = rows
        .map((row) => row['session_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (sessions.isEmpty) {
      return TraeMergeResult(
        sourceSessions: sourceSessions,
        newSessions: 0,
        tables: const {},
        skipped: const [],
        dryRun: false,
      );
    }

    final sessionList = _inSet(sessions);
    final messages = await _ids(
      db,
      'SELECT message_id AS v FROM src.chat_message WHERE session_id IN ($sessionList)',
    );
    final turns = await _ids(
      db,
      'SELECT turn_id AS v FROM src.chat_turn WHERE session_id IN ($sessionList)',
    );
    final runs = await _ids(
      db,
      'SELECT agent_run_id AS v FROM src.agent_run WHERE session_id IN ($sessionList)',
    );
    final requirements = await _ids(
      db,
      'SELECT requirement_id AS v FROM src.chat_turn WHERE session_id IN ($sessionList)',
    );
    final tasks = await _ids(
      db,
      'SELECT id AS v FROM src.task WHERE session_id IN ($sessionList)',
    );
    final projects = await _ids(
      db,
      'SELECT project_id AS v FROM src.chat_session WHERE session_id IN ($sessionList)',
    );
    projects.addAll(
      await _ids(
        db,
        'SELECT project_id AS v FROM src.session_project WHERE session_id IN ($sessionList)',
      ),
    );
    // todo_list 没有会话列，只能经 history_todo_list.message_id 二级关联。
    final todos = await _ids(
      db,
      'SELECT DISTINCT todo_list_id AS v FROM src.history_todo_list '
      'WHERE message_id IN (${_inSet(messages)})',
    );

    final packTables = await _tables(db, 'src');
    final dstTables = await _tables(db, 'main');
    final dstNames = dstTables.map((t) => t.name).toSet();
    final fts = packTables
        .where((t) => t.sql.toLowerCase().contains('using fts'))
        .map((t) => t.name)
        .toList();

    final report = <String, (int, int)>{};
    final skipped = <String>[];

    await db.transaction((txn) async {
      for (final table in packTables) {
        if (table.name == 'sqlite_sequence') continue;
        if (fts.any((name) => table.name.startsWith('${name}_'))) continue;

        final info = await _columns(txn, table.name, 'src');
        if (info.isEmpty) {
          skipped.add('${table.name}(取列失败)');
          continue;
        }
        final rules = _linkRules(
          table.name,
          info.map((c) => c.name).toList(),
          sessions: sessions,
          messages: messages,
          turns: turns,
          runs: runs,
          requirements: requirements,
          tasks: tasks,
          projects: projects,
          todos: todos,
        );
        if (rules.isEmpty) {
          skipped.add(table.name);
          continue;
        }

        if (!dstNames.contains(table.name)) {
          await txn.execute(
            table.sql.replaceFirst(
              RegExp('create table', caseSensitive: false),
              'CREATE TABLE IF NOT EXISTS',
            ),
          );
        }
        final dstCols = (await _columns(
          txn,
          table.name,
          'main',
        )).map((c) => c.name).toSet();
        var cols = info.map((c) => c.name).where(dstCols.contains).toList();
        // 整数自增主键交给目标库重新分配；文本 uuid 主键保留。
        final integerId = info.any(
          (c) =>
              c.name == 'id' &&
              c.pk == 1 &&
              c.type.toUpperCase().contains('INT'),
        );
        if (integerId) cols = cols.where((c) => c != 'id').toList();
        if (cols.isEmpty) {
          skipped.add('${table.name}(无公共列)');
          continue;
        }

        final where = rules
            .map((rule) => '"${_quoteIdent(rule.$1)}" IN (${_inSet(rule.$2)})')
            .join(' OR ');
        final total = await _countWhere(txn, table.name, where);
        if (total == 0) continue;

        if (await _missingRequired(txn, table.name, cols)) {
          throw TraeMigrationException(
            '目标表 ${table.name} 有源表没有的非空无默认列（两端 Trae 版本不一致？），已中止，目标库未改动',
          );
        }

        final quoted = cols.map((c) => '"${_quoteIdent(c)}"').join(',');
        await txn.execute(
          'INSERT OR IGNORE INTO main."${_quoteIdent(table.name)}" ($quoted) '
          'SELECT $quoted FROM src."${_quoteIdent(table.name)}" WHERE $where',
        );
        final changed = await txn.rawQuery('SELECT changes() AS n');
        final inserted = (changed.first['n'] as int?) ?? 0;
        report[table.name] = (inserted, total);
      }
    });

    return TraeMergeResult(
      sourceSessions: sourceSessions,
      newSessions: sessions.length,
      tables: report,
      skipped: skipped,
      dryRun: false,
    );
  }

  /// 一行的任一关联列挂上新实体即迁（多列 OR 并集）。
  ///
  /// 实测的病态数据：history_todo_list.session_id 全空串、
  /// server_history_info 的真键是 conversation_id，所以按列名多路匹配。
  List<(String, Set<String>)> _linkRules(
    String table,
    List<String> cols, {
    required Set<String> sessions,
    required Set<String> messages,
    required Set<String> turns,
    required Set<String> runs,
    required Set<String> requirements,
    required Set<String> tasks,
    required Set<String> projects,
    required Set<String> todos,
  }) {
    final rules = <(String, Set<String>)>[];
    void add(String column, Set<String> values) {
      if (cols.contains(column) && values.isNotEmpty) {
        rules.add((column, values));
      }
    }

    add('session_id', sessions);
    add('conversation_id', sessions);
    add('chat_session_id', sessions);
    add('creator_session_id', sessions);
    add('writer_session_id', sessions);
    add('message_id', messages);
    add('chat_message_id', messages);
    add('turn_id', turns);
    add('creator_turn_id', turns);
    add('writer_turn_id', turns);
    add('agent_run_id', runs);
    add('requirement_id', requirements);
    add('task_id', tasks);
    if (table == 'project') add('project_id', projects);
    if (table == 'todo_list') add('id', todos);
    return rules;
  }

  /// 写回：重加密 → 自校验 → 备份 → 原子替换。
  Future<String> _writeBack(
    String target,
    String plainPath,
    String keyHex,
  ) async {
    final plain = await File(plainPath).readAsBytes();
    final salt = await _head(target, 16);
    final encrypted = TraeDbCipher.encryptDatabase(plain, keyHex, salt);
    if (!TraeDbCipher.matchesPlain(encrypted, plain, keyHex)) {
      throw const TraeMigrationException('重加密自校验失败，目标库未改动');
    }

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp('[:.T-]'), '')
        .substring(0, 14);
    final backup = '$target.bak-$stamp';
    final permission = (await File(target).stat()).mode & 0x1ff;
    final staging = '$target.new-$stamp';

    try {
      await File(target).rename(backup);
      for (final suffix in const ['-wal', '-shm']) {
        final side = File('$target$suffix');
        if (await side.exists()) await side.rename('$backup$suffix');
      }
      await File(staging).writeAsBytes(encrypted, flush: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', [permission.toRadixString(8), staging]);
      }
      await File(staging).rename(target);
    } catch (error) {
      try {
        if (!await File(target).exists() && await File(backup).exists()) {
          await File(backup).rename(target);
        }
      } catch (_) {
        // 忽略。
      }
      throw TraeMigrationException('替换失败，已回滚：$error');
    }

    if (!TraeDbCipher.validateKey(keyHex, target)) {
      throw TraeMigrationException('替换后校验异常，请用备份恢复：$backup');
    }
    return backup;
  }

  // ---------------------------------------------------------------------------
  // SQL 辅助
  // ---------------------------------------------------------------------------

  Future<int> _count(Database db, String table) async {
    try {
      final rows = await db.rawQuery('SELECT count(*) AS n FROM $table');
      return (rows.first['n'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _countWhere(
    DatabaseExecutor db,
    String table,
    String where,
  ) async {
    final rows = await db.rawQuery(
      'SELECT count(*) AS n FROM src."${_quoteIdent(table)}" WHERE $where',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<Set<String>> _ids(Database db, String sql) async {
    try {
      final rows = await db.rawQuery(sql);
      return rows
          .map((row) => row['v']?.toString() ?? '')
          .where((value) => value.isNotEmpty)
          .toSet();
    } catch (_) {
      // 该版本没有这张表/列。
      return <String>{};
    }
  }

  Future<List<({String name, String sql})>> _tables(
    DatabaseExecutor db,
    String schema,
  ) async {
    final rows = await db.rawQuery(
      "SELECT name, ifnull(sql, '') AS sql FROM $schema.sqlite_master "
      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return rows
        .map(
          (row) => (
            name: row['name']?.toString() ?? '',
            sql: row['sql']?.toString() ?? '',
          ),
        )
        .where((table) => table.name.isNotEmpty)
        .toList();
  }

  Future<List<({String name, String type, int pk})>> _columns(
    DatabaseExecutor db,
    String table,
    String schema,
  ) async {
    final rows = await db.rawQuery(
      'SELECT name, type, pk FROM pragma_table_info(?, ?)',
      [table, schema],
    );
    return rows
        .map(
          (row) => (
            name: row['name']?.toString() ?? '',
            type: row['type']?.toString() ?? '',
            pk: (row['pk'] as int?) ?? 0,
          ),
        )
        .toList();
  }

  /// 目标表是否有「非空且无默认」而源表不提供的列。
  Future<bool> _missingRequired(
    DatabaseExecutor db,
    String table,
    List<String> provided,
  ) async {
    final rows = await db.rawQuery(
      'SELECT name, "notnull" AS nn, dflt_value AS dv, pk '
      "FROM pragma_table_info(?, 'main')",
      [table],
    );
    return rows.any(
      (row) =>
          row['nn'] == 1 &&
          row['dv'] == null &&
          (row['pk'] as int? ?? 0) == 0 &&
          !provided.contains(row['name']?.toString()),
    );
  }

  // ---------------------------------------------------------------------------
  // 文件辅助
  // ---------------------------------------------------------------------------

  static String _defaultPackPath() {
    final home = AppPaths.home;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp('[:.T-]'), '')
        .substring(0, 15);
    return p.join(home, 'trae-pack-$stamp.db');
  }

  static bool _hasMagic(Uint8List head) {
    if (head.length < 16) return false;
    for (var i = 0; i < 16; i++) {
      if (head[i] != TraeDbCipher.magic[i]) return false;
    }
    return true;
  }

  static Future<Uint8List> _head(String path, int length) async {
    final file = await File(path).open();
    try {
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  static String _inSet(Set<String> values) {
    if (values.isEmpty) return 'NULL';
    return values.map((value) => "'${_quote(value)}'").join(',');
  }

  static String _quote(String value) => value.replaceAll("'", "''");

  static String _quoteIdent(String value) => value.replaceAll('"', '""');
}
