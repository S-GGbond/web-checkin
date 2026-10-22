import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/account.dart';
import '../../util/app_paths.dart';
import '../desktop/desktop_client.dart';
import 'session_service.dart';
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

/// 一次「复制会话到另一个账号」的结果（[tables] 为 表名 → 复制的行数）。
class TraeCopyResult {
  const TraeCopyResult({
    required this.toUid,
    required this.sessions,
    required this.tables,
    required this.skipped,
    required this.newSessionIds,
    required this.createdProjects,
    required this.projectPaths,
    required this.dryRun,
    this.backupPath,
  });

  final String toUid;

  /// 实际复制成功的会话数。
  final int sessions;

  /// 表名 → 复制的行数。
  final Map<String, int> tables;

  /// 没有会话关联、因而跳过的表。
  final List<String> skipped;

  /// 旧会话 id → 副本会话 id。
  final Map<String, String> newSessionIds;

  /// 为目标账号新建的项目行数量（同路径项目直接复用）。
  final int createdProjects;

  /// 副本所在的项目路径（Trae 按工作区过滤会话，需要打开对应文件夹才看得到）。
  final List<String> projectPaths;
  final bool dryRun;
  final String? backupPath;

  int get rows => tables.values.fold(0, (sum, count) => sum + count);
}

/// 内部：复制过程的行数与新 id 映射。
class _CopyOutcome {
  const _CopyOutcome({
    required this.tables,
    required this.sessions,
    required this.newSessionIds,
    required this.createdProjects,
    required this.projectPaths,
    required this.skipped,
  });

  final Map<String, int> tables;
  final int sessions;
  final Map<String, String> newSessionIds;
  final int createdProjects;
  final List<String> projectPaths;
  final List<String> skipped;

  int get total => tables.values.fold(0, (sum, count) => sum + count);
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
          validate: (candidate) => TraeDbCipher.validateKey(candidate, target),
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
  // 复制会话到另一个账号（原账号保留）
  // ---------------------------------------------------------------------------

  /// 账号级 / 配置级表：两端各有一份，复制会话时整表跳过。
  static const Set<String> _copySkipTables = {
    'seaql_migrations',
    'migration_sql_store',
    'user_configuration',
    'model_config_cache',
    'agent',
    'agent_member_relation',
    'mcp_server_agent_relation',
    'core_memory',
  };

  /// 每行实体自己的 id 列：复制时换成新 id。
  static const Map<String, String> _identityColumns = {
    'chat_session': 'session_id',
    'chat_message': 'message_id',
    'chat_turn': 'turn_id',
    'task': 'task_id',
    'agent_run': 'agent_run_id',
    'history_v2': 'history_v2_id',
    'plan': 'plan_id',
    'plan_item': 'plan_item_id',
    'plan_item_core_memory_snapshot': 'picms_id',
    'proposal': 'proposal_id',
    'chat_requirement': 'requirement_id',
    'checkpoint': 'checkpoint_id',
    'snapshot': 'snapshot_id',
    'staging': 'staging_id',
    'worktree': 'worktree_id',
    'chat_session_goal': 'goal_id',
    'local_artifact': 'artifact_id',
    'scheduled_task_executions': 'execution_id',
    'toolcall': 'toolcall_id',
    'server_history_info': 'history_id',
    'im_session_route': 'route_key',
  };

  /// 关联列：从选中会话出发，按这些列在整个库里做闭包收集。
  static const Set<String> _linkColumns = {
    'session_id',
    'conversation_id',
    'chat_session_id',
    'creator_session_id',
    'writer_session_id',
    'message_id',
    'chat_message_id',
    'reply_to_message_id',
    'response_message_id',
    'turn_id',
    'creator_turn_id',
    'writer_turn_id',
    'last_unread_turn_id',
    'task_id',
    'agent_run_id',
    'parent_run_id',
    'history_v2_id',
    'plan_id',
    'plan_item_id',
    'guideline_id',
    'proposal_id',
    'requirement_id',
    'checkpoint_id',
    'snapshot_id',
    'staging_id',
    'worktree_id',
    'goal_id',
    'artifact_id',
    'toolcall_id',
    'history_id',
    'client_history_id',
  };

  /// 文本里内嵌 id 的列（会话 context、快照 state 等）：同步替换会话与项目 id。
  static const Set<String> _embeddedIdColumns = {
    'context',
    'additional_context',
    'state',
    'extra',
  };

  /// 把 [sessionIds]（属于 [fromUid]）复制一份到 [toUid] 名下，原会话不动。
  ///
  /// 复制范围是整条会话图：会话、消息、回合、任务、agent run、历史、服务端历史、
  /// 快照 / staging / worktree、工件与待办，行里所有实体 id 都换成新 id；
  /// 目标账号没有同路径项目时新建一行，有则复用。写回前做完整性校验，原库自动备份。
  ///
  /// [dryRun] 只试算不写回；[requireClientClosed] 在写本机默认库时要求 Trae 已退出。
  Future<TraeCopyResult> copySessions({
    required String toUid,
    required Set<String> sessionIds,
    String? fromUid,
    String? dbPath,
    String? key,
    bool dryRun = false,
    bool requireClientClosed = true,
    List<String>? stateRoots,
    void Function(String message)? log,
  }) async {
    if (toUid.isEmpty) {
      throw const TraeMigrationException('需要目标账号');
    }
    if (sessionIds.isEmpty) {
      throw const TraeMigrationException('没有选中任何会话');
    }

    final target = dbPath ?? TraeChatDb.defaultDatabasePath();
    if (target == null) {
      throw const TraeMigrationException('没有找到 Trae 客户端的会话数据库');
    }
    if (!await File(target).exists()) {
      throw TraeMigrationException('会话数据库不存在：$target');
    }
    if (requireClientClosed) {
      final pids = await DesktopClient.runningPids(PlatformKind.trae);
      if (pids.isNotEmpty) {
        final ids = pids.join(', ');
        throw TraeMigrationException(
          'Trae 正在运行（pid $ids），请先完全退出再复制，否则写入会被客户端覆盖',
        );
      }
    }

    final targetKey =
        key ??
        await TraeDbKey.resolve(
          dbPath: target,
          validate: (candidate) => TraeDbCipher.validateKey(candidate, target),
          log: log,
        );
    if (targetKey == null) {
      throw const TraeMigrationException('未能取得会话库密钥');
    }

    final work = await Directory.systemTemp.createTemp('checkin-hub-copy-');
    Database? db;
    try {
      final plain = await TraeChatDb.decryptToPlain(
        targetKey,
        target,
        await Directory(p.join(work.path, 'dst')).create(recursive: true),
      );
      db = await TraeChatDb.openPlain(plain, readOnly: false);
      await db.execute('PRAGMA journal_mode = DELETE');

      final outcome = await _copyInto(
        db,
        sessionIds: sessionIds,
        toUid: toUid,
        dryRun: dryRun,
        log: log,
      );

      await db.execute('PRAGMA journal_mode = DELETE');
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      final verdict = integrity.isEmpty
          ? ''
          : integrity.first.values.first?.toString() ?? '';
      if (verdict != 'ok') {
        throw TraeMigrationException('复制后完整性校验失败：$verdict（目标库未改动）');
      }
      await db.close();
      db = null;

      if (outcome.sessions == 0 || dryRun) {
        return TraeCopyResult(
          toUid: toUid,
          sessions: outcome.sessions,
          tables: outcome.tables,
          skipped: outcome.skipped,
          newSessionIds: outcome.newSessionIds,
          createdProjects: outcome.createdProjects,
          projectPaths: outcome.projectPaths,
          dryRun: dryRun,
        );
      }

      final backup = await _writeBack(target, plain, targetKey);

      // 客户端按 draft:session 键判断会话属于哪个账号：给副本补一份新键，
      // 否则重启客户端后副本会算回原账号。
      if (fromUid != null && fromUid.isNotEmpty) {
        await _copyStateOwnership(
          fromUid: fromUid,
          toUid: toUid,
          sessionIds: outcome.newSessionIds,
          roots: stateRoots,
        );
      }

      return TraeCopyResult(
        toUid: toUid,
        sessions: outcome.sessions,
        tables: outcome.tables,
        skipped: outcome.skipped,
        newSessionIds: outcome.newSessionIds,
        createdProjects: outcome.createdProjects,
        projectPaths: outcome.projectPaths,
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

  /// 在已解密的目标库里完成一次复制（事务内插入；任何一步失败都整体回滚）。
  Future<_CopyOutcome> _copyInto(
    Database db, {
    required Set<String> sessionIds,
    required String toUid,
    required bool dryRun,
    void Function(String message)? log,
  }) async {
    final tables = (await _tables(db, 'main')).where((table) {
      if (_copySkipTables.contains(table.name)) return false;
      // FTS 虚表与影子表交给触发器维护，直接复制会弄坏索引。
      if (table.name.startsWith('fts_')) return false;
      return !table.sql.toLowerCase().contains('virtual table');
    }).toList();
    final columns = <String, List<({String name, String type, int pk})>>{};
    final linkedTables = <String, List<String>>{};
    for (final table in tables) {
      final info = await _columns(db, table.name, 'main');
      columns[table.name] = info;
      for (final column in info) {
        if (_linkColumns.contains(column.name)) {
          (linkedTables[column.name] ??= <String>[]).add(table.name);
        }
      }
    }

    // 1) 从选中会话出发，按关联列做闭包：把整条会话图的行都收集出来。
    final collected = <String, Map<int, Map<String, Object?>>>{};
    final idMap = <String, String>{};
    final seen = <String>{};
    var pending = <String>{};
    for (final id in sessionIds) {
      if (id.isEmpty || !seen.add(id)) continue;
      idMap[id] = _newId('chat_session');
      pending.add(id);
    }
    if (pending.isEmpty) {
      return const _CopyOutcome(
        tables: {},
        sessions: 0,
        newSessionIds: {},
        createdProjects: 0,
        projectPaths: [],
        skipped: [],
      );
    }

    void absorb(String table, List<Map<String, Object?>> rows) {
      if (rows.isEmpty) return;
      final bucket = collected.putIfAbsent(
        table,
        () => <int, Map<String, Object?>>{},
      );
      for (final row in rows) {
        final rid = row['__rid'];
        if (rid is! int || bucket.containsKey(rid)) continue;
        bucket[rid] = row;
        final identity = _identityColumns[table];
        if (identity == null) continue;
        final value = row[identity]?.toString() ?? '';
        if (value.isEmpty || !seen.add(value)) continue;
        idMap[value] = _newId(table);
        pending.add(value);
      }
    }

    while (pending.isNotEmpty) {
      final wave = pending.toList(growable: false);
      pending = <String>{};
      for (final entry in linkedTables.entries) {
        for (var offset = 0; offset < wave.length; offset += 400) {
          final chunk = wave.sublist(offset, min(offset + 400, wave.length));
          final marks = List.filled(chunk.length, '?').join(',');
          for (final table in entry.value) {
            final rows = await db.rawQuery(
              'SELECT rowid AS __rid, * FROM "${_quoteIdent(table)}" '
              'WHERE "${_quoteIdent(entry.key)}" IN ($marks)',
              chunk,
            );
            absorb(table, rows);
          }
        }
      }
    }

    // todo_list 没有会话列，只能经 history_todo_list.todo_list_id 二级关联。
    final todoIds = <int>{};
    for (final row
        in collected['history_todo_list']?.values ??
            const <Map<String, Object?>>[]) {
      final value = row['todo_list_id'];
      if (value is int) todoIds.add(value);
    }
    if (todoIds.isNotEmpty) {
      final marks = List.filled(todoIds.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT rowid AS __rid, * FROM todo_list WHERE id IN ($marks)',
        todoIds.toList(),
      );
      absorb('todo_list', rows);
    }

    final sessions = collected['chat_session'];
    if (sessions == null || sessions.isEmpty) {
      return const _CopyOutcome(
        tables: {},
        sessions: 0,
        newSessionIds: {},
        createdProjects: 0,
        projectPaths: [],
        skipped: [],
      );
    }

    // 2) 目标账号的项目行：同路径复用，没有就复制一份。
    final projects = <String, String>{};
    var createdProjects = 0;
    for (final row in sessions.values) {
      final oldPid = row['project_id']?.toString() ?? '';
      if (oldPid.isEmpty || projects.containsKey(oldPid)) continue;
      final mapped = await _targetProject(
        db,
        sourcePid: oldPid,
        toUid: toUid,
        dryRun: dryRun,
      );
      projects[oldPid] = mapped.pid;
      if (mapped.created) createdProjects++;
    }
    // Trae 的会话列表按工作区（打开的文件夹）过滤，把这些路径回报给用户。
    final projectPaths = <String>[];
    for (final oldPid in projects.keys) {
      try {
        final rows = await db.query(
          'project',
          columns: ['absolute_path'],
          where: 'project_id = ?',
          whereArgs: [oldPid],
          limit: 1,
        );
        final path = rows.isEmpty
            ? ''
            : rows.first['absolute_path']?.toString() ?? '';
        if (path.isNotEmpty && !projectPaths.contains(path)) {
          projectPaths.add(path);
        }
      } catch (_) {
        // 项目表结构异常时忽略。
      }
    }
    log?.call('目标项目 ${projects.length} 个（新建 $createdProjects 个）');

    // 3) 换新 id 后写回；整数自增主键交给 SQLite 重新分配。
    final counts = <String, int>{};
    final todoIdMap = <int, int>{};
    final historyTodos = <({int rowid, Object? todo})>[];

    Future<void> write(DatabaseExecutor txn) async {
      for (final entry in collected.entries) {
        final table = entry.key;
        if (table == 'project') continue;
        final info = columns[table]!;
        final identity = _identityColumns[table];
        for (final row in entry.value.values) {
          final values = <String, Object?>{};
          for (final column in info) {
            if (column.name == 'id') continue;
            final raw = row[column.name];
            values[column.name] = raw is String && raw.isNotEmpty
                ? _copyText(
                    column: column.name,
                    value: raw,
                    toUid: toUid,
                    idMap: idMap,
                    projects: projects,
                    sessionIds: sessionIds,
                  )
                : raw;
          }
          if (identity != null && (values[identity]?.toString() ?? '').isEmpty) {
            values[identity] =
                idMap[row[identity]?.toString()] ?? _newId(table);
          }
          if (table == 'chat_session' && values.containsKey('updated_at')) {
            values['updated_at'] =
                DateTime.now().millisecondsSinceEpoch ~/ 1000;
          }

          counts[table] = (counts[table] ?? 0) + 1;
          if (dryRun) continue;

          final names = values.keys.toList(growable: false);
          final quoted = names
              .map((name) => '"${_quoteIdent(name)}"')
              .join(',');
          final marks = List.filled(names.length, '?').join(',');
          final verb = table == 'local_artifact'
              ? 'INSERT OR IGNORE'
              : 'INSERT';
          final rowid = await txn.rawInsert(
            '$verb INTO "${_quoteIdent(table)}" ($quoted) VALUES ($marks)',
            [for (final name in names) values[name]],
          );
          if (table == 'todo_list') {
            final old = row['id'];
            if (old is int) todoIdMap[old] = rowid;
          }
          if (table == 'history_todo_list') {
            historyTodos.add((rowid: rowid, todo: row['todo_list_id']));
          }
        }
      }

      // 待办主表换了自增 id，明细里的 todo_list_id 跟着改。
      for (final item in historyTodos) {
        final old = item.todo;
        if (old is! int) continue;
        final next = todoIdMap[old];
        if (next == null) continue;
        await txn.rawUpdate(
          'UPDATE history_todo_list SET todo_list_id = ? WHERE rowid = ?',
          [next, item.rowid],
        );
      }
    }

    if (dryRun) {
      await write(db);
    } else {
      await db.transaction((txn) async => write(txn));
    }

    return _CopyOutcome(
      tables: counts,
      sessions: sessions.length,
      newSessionIds: {
        for (final id in sessionIds)
          if (idMap[id] != null) id: idMap[id]!,
      },
      createdProjects: createdProjects,
      projectPaths: projectPaths,
      skipped: [
        for (final table in tables)
          if (collected[table.name] == null) table.name,
      ],
    );
  }

  /// 把一行的文本列换成副本里的值：账号、项目、实体 id、内嵌 id 分别处理。
  String _copyText({
    required String column,
    required String value,
    required String toUid,
    required Map<String, String> idMap,
    required Map<String, String> projects,
    required Set<String> sessionIds,
  }) {
    if (column == 'user_id') return toUid;
    if (column == 'project_id' ||
        column == 'source_project_id' ||
        column == 'local_project_id') {
      return projects[value] ?? value;
    }
    final mapped = idMap[value];
    if (mapped != null) return mapped;
    if (_embeddedIdColumns.contains(column)) {
      var text = value;
      for (final id in sessionIds) {
        final next = idMap[id];
        if (next != null && text.contains(id)) text = text.replaceAll(id, next);
      }
      for (final entry in projects.entries) {
        if (text.contains(entry.key)) {
          text = text.replaceAll(entry.key, entry.value);
        }
      }
      return text;
    }
    return value;
  }

  /// 目标账号里同路径的项目行；没有就复制一份（新 project_id + 新的云端绑定）。
  Future<({String pid, bool created})> _targetProject(
    DatabaseExecutor db, {
    required String sourcePid,
    required String toUid,
    required bool dryRun,
  }) async {
    final source = await db.query(
      'project',
      where: 'project_id = ?',
      whereArgs: [sourcePid],
      limit: 1,
    );
    if (source.isEmpty) {
      throw TraeMigrationException('找不到会话所属项目：$sourcePid');
    }
    final row = source.first;
    final path = row['absolute_path']?.toString() ?? '';
    if (path.isNotEmpty) {
      final existing = await db.query(
        'project',
        where: 'absolute_path = ? AND user_id = ?',
        whereArgs: [path, toUid],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return (pid: existing.first['project_id'].toString(), created: false);
      }
    }

    final pid = _randomHex(24);
    if (!dryRun) {
      final copy = Map<String, Object?>.from(row)..remove('id');
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      copy['project_id'] = pid;
      copy['user_id'] = toUid;
      if (copy.containsKey('biz_project_id')) {
        copy['biz_project_id'] = _randomHex(32);
      }
      if (copy.containsKey('remote_project_id')) {
        copy['remote_project_id'] = null;
      }
      if (copy.containsKey('created_at')) copy['created_at'] = now;
      if (copy.containsKey('updated_at')) copy['updated_at'] = now;
      if (copy.containsKey('deleted_at')) copy['deleted_at'] = 0;
      await db.insert('project', copy);
    }
    return (pid: pid, created: true);
  }

  /// 给副本补一份目标账号的 draft:session 键，原键保留。
  Future<void> _copyStateOwnership({
    required String fromUid,
    required String toUid,
    required Map<String, String> sessionIds,
    List<String>? roots,
  }) async {
    if (fromUid.isEmpty || sessionIds.isEmpty) return;
    for (final root in roots ?? SessionService.traeConfigRoots()) {
      final paths = <String>[
        p.join(root, 'User', 'globalStorage', 'state.vscdb'),
      ];
      final workspaceStorage = Directory(
        p.join(root, 'User', 'workspaceStorage'),
      );
      if (await workspaceStorage.exists()) {
        try {
          await for (final entry in workspaceStorage.list()) {
            if (entry is Directory) {
              paths.add(p.join(entry.path, 'state.vscdb'));
            }
          }
        } catch (_) {
          // 忽略。
        }
      }

      for (final path in paths) {
        if (!await File(path).exists()) continue;
        Database? db;
        try {
          db = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(singleInstance: false),
          );
          for (final entry in sessionIds.entries) {
            final oldId = entry.key;
            final newId = entry.value;
            final prefix = '$fromUid:draft:session:$oldId:';
            final drafts = await db.query(
              'ItemTable',
              where: 'key LIKE ?',
              whereArgs: ['$prefix%'],
            );
            for (final row in drafts) {
              final key = row['key']?.toString() ?? '';
              if (!key.startsWith(prefix)) continue;
              final value = (row['value'] ?? '')
                  .toString()
                  .replaceAll(oldId, newId)
                  .replaceAll(fromUid, toUid);
              await db.insert('ItemTable', {
                'key':
                    '$toUid:draft:session:$newId:${key.substring(prefix.length)}',
                'value': value,
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }

            // 补全缓存键：ai-chat.chatQueryCompletion.vN.<sessionId>
            final completions = await db.query(
              'ItemTable',
              where: 'key LIKE ?',
              whereArgs: ['ai-chat.chatQueryCompletion.%$oldId'],
            );
            for (final row in completions) {
              final key = row['key']?.toString() ?? '';
              if (!key.endsWith(oldId)) continue;
              final value = (row['value'] ?? '')
                  .toString()
                  .replaceAll(oldId, newId);
              await db.insert('ItemTable', {
                'key':
                    '${key.substring(0, key.length - oldId.length)}$newId',
                'value': value,
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
          }
        } catch (_) {
          // 状态库被占用时跳过：本地归属记录仍会兜底分组。
        } finally {
          try {
            await db?.close();
          } catch (_) {
            // 忽略。
          }
        }
      }
    }
  }

  static String _randomHex(int length) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  /// 会话 / 消息 / 回合这类 id 是 24 位十六进制；agent_run 用 UUID。
  static String _newId(String table) =>
      table == 'agent_run' ? _uuid() : _randomHex(24);

  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
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
