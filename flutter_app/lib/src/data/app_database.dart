import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/account.dart';
import '../models/checkin_log.dart';
import '../util/json_utils.dart';

/// 统一账号库。表结构与 Python 版 `account_store.py` 完全对齐，
/// 便于两个客户端读写同一份 `checkin-hub.sqlite3`。
class AppDatabase {
  AppDatabase._(this._db, this.path);

  final Database _db;

  /// 账号库文件路径；内存库为 `:memory:`。渲染层可直接展示，无需再次做 I/O。
  final String path;

  static bool _ffiReady = false;

  static Future<AppDatabase> open() async {
    final path = await resolveDatabasePath();
    final factory = _configureFactory();
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA busy_timeout = 5000');
        },
        onCreate: (db, _) async => _createSchema(db),
        onUpgrade: (db, _, _) async => _migrate(db),
      ),
    );
    await _applyFilePermissions(path);
    return AppDatabase._(db, path);
  }

  /// 仅测试使用：内存数据库。
  static Future<AppDatabase> openInMemory() async {
    _ensureFfiInitialized();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        // 每个内存库都必须独立，否则同进程内多次打开会复用同一个连接。
        singleInstance: false,
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async => _createSchema(db),
      ),
    );
    return AppDatabase._(db, inMemoryDatabasePath);
  }

  static DatabaseFactory _configureFactory() {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      _ensureFfiInitialized();
      return databaseFactoryFfi;
    }
    return databaseFactory;
  }

  static void _ensureFfiInitialized() {
    if (_ffiReady) return;
    sqfliteFfiInit();
    _ffiReady = true;
  }

  /// 数据目录解析，与 Python `paths.py` 保持一致：
  /// `WEB_CHECKIN_HOME` 覆盖目录，`CHECKIN_HUB_DB` 直接覆盖文件。
  static Future<String> resolveDatabasePath() async {
    final explicit = Platform.environment['CHECKIN_HUB_DB'];
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final homeOverride = Platform.environment['WEB_CHECKIN_HOME'];
    String base;
    if (homeOverride != null && homeOverride.isNotEmpty) {
      base = homeOverride;
    } else {
      final dir = await getApplicationSupportDirectory();
      base = dir.path;
    }
    final target = Directory(base);
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return p.join(base, 'checkin-hub.sqlite3');
  }

  static Future<void> _applyFilePermissions(String path) async {
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run('chmod', ['600', path]);
      } catch (_) {
        // 忽略：某些文件系统不支持权限位。
      }
    }
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provider TEXT NOT NULL,
        external_id TEXT NOT NULL,
        display_name TEXT NOT NULL DEFAULT '',
        label TEXT NOT NULL DEFAULT '',
        endpoint TEXT NOT NULL,
        credential TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        last_status TEXT,
        last_status_at INTEGER,
        last_checkin_at INTEGER,
        last_checkin_ok INTEGER,
        last_checkin_message TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        schedule_time TEXT NOT NULL DEFAULT '09:00',
        schedule_enabled INTEGER NOT NULL DEFAULT 1,
        schedule_last_date TEXT,
        UNIQUE(provider, external_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS checkin_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL,
        provider TEXT NOT NULL,
        action TEXT NOT NULL,
        ok INTEGER NOT NULL,
        code INTEGER,
        message TEXT,
        payload_json TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY(account_id) REFERENCES accounts(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_checkin_logs_account_time ON checkin_logs(account_id, created_at)',
    );
  }

  static Future<void> _migrate(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(accounts)');
    final names = columns.map((c) => c['name'] as String).toSet();
    if (!names.contains('schedule_time')) {
      await db.execute("ALTER TABLE accounts ADD COLUMN schedule_time TEXT NOT NULL DEFAULT '09:00'");
    }
    if (!names.contains('schedule_enabled')) {
      await db.execute('ALTER TABLE accounts ADD COLUMN schedule_enabled INTEGER NOT NULL DEFAULT 1');
    }
    if (!names.contains('schedule_last_date')) {
      await db.execute('ALTER TABLE accounts ADD COLUMN schedule_last_date TEXT');
    }
  }

  Future<void> close() => _db.close();

  // ---------------------------------------------------------------------------
  // 账号
  // ---------------------------------------------------------------------------

  static const _providerOrder = "CASE provider WHEN 'workbuddy' THEN 0 WHEN 'trae' THEN 1 ELSE 2 END";

  Future<List<Account>> listAccounts({bool enabledOnly = false}) async {
    final sql = StringBuffer('SELECT * FROM accounts');
    if (enabledOnly) sql.write(' WHERE enabled = 1');
    sql.write(' ORDER BY $_providerOrder, created_at, id');
    final rows = await _db.rawQuery(sql.toString());
    return rows.map(Account.fromRow).toList();
  }

  /// 返回包含凭据的原始行（供平台服务使用）。
  Future<List<Map<String, Object?>>> listAccountRows({bool enabledOnly = false}) async {
    final sql = StringBuffer('SELECT * FROM accounts');
    if (enabledOnly) sql.write(' WHERE enabled = 1');
    sql.write(' ORDER BY $_providerOrder, created_at, id');
    return _db.rawQuery(sql.toString());
  }

  Future<Map<String, Object?>?> getAccountRow(int id) async {
    final rows = await _db.query('accounts', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Account?> getAccount(int id) async {
    final row = await getAccountRow(id);
    return row == null ? null : Account.fromRow(row);
  }

  Future<int> upsertAccount({
    required PlatformKind provider,
    required String externalId,
    required String displayName,
    required String endpoint,
    required String credential,
    String label = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.rawInsert(
      '''
      INSERT INTO accounts (
        provider, external_id, display_name, label, endpoint, credential,
        enabled, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT(provider, external_id) DO UPDATE SET
        display_name = CASE WHEN excluded.display_name = '' THEN accounts.display_name ELSE excluded.display_name END,
        label = CASE WHEN excluded.label = '' THEN accounts.label ELSE excluded.label END,
        endpoint = excluded.endpoint,
        credential = excluded.credential,
        enabled = 1,
        updated_at = excluded.updated_at
      ''',
      [provider.id, externalId, displayName, label, endpoint, credential, now, now],
    );
    final rows = await _db.query(
      'accounts',
      columns: ['id'],
      where: 'provider = ? AND external_id = ?',
      whereArgs: [provider.id, externalId],
      limit: 1,
    );
    return rows.first['id'] as int;
  }

  Future<void> updateCredential(int id, {required String credential, String? displayName}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.rawUpdate(
      'UPDATE accounts SET credential = ?, display_name = COALESCE(?, display_name), updated_at = ? WHERE id = ?',
      [credential, displayName, now, id],
    );
  }

  Future<void> updateStatus(int id, Map<String, dynamic>? status) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.rawUpdate(
      'UPDATE accounts SET last_status = ?, last_status_at = ?, updated_at = ? WHERE id = ?',
      [status == null ? null : jsonEncodeSorted(status), now, now, id],
    );
  }

  Future<void> updateCheckin(int id, {required bool ok, required String message}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.rawUpdate(
      'UPDATE accounts SET last_checkin_at = ?, last_checkin_ok = ?, last_checkin_message = ?, updated_at = ? WHERE id = ?',
      [now, ok ? 1 : 0, message.length > 500 ? message.substring(0, 500) : message, now, id],
    );
  }

  Future<bool> setEnabled(int id, bool enabled) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final count = await _db.rawUpdate(
      'UPDATE accounts SET enabled = ?, updated_at = ? WHERE id = ?',
      [enabled ? 1 : 0, now, id],
    );
    return count == 1;
  }

  Future<bool> updateSchedule(int id, {required bool enabled, required String time}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final count = await _db.rawUpdate(
      'UPDATE accounts SET schedule_enabled = ?, schedule_time = ?, updated_at = ? WHERE id = ?',
      [enabled ? 1 : 0, time, now, id],
    );
    return count == 1;
  }

  Future<void> markScheduleRun(int id, String runDate) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.rawUpdate(
      'UPDATE accounts SET schedule_last_date = ?, updated_at = ? WHERE id = ?',
      [runDate, now, id],
    );
  }

  Future<bool> deleteAccount(int id) async {
    final count = await _db.delete('accounts', where: 'id = ?', whereArgs: [id]);
    return count == 1;
  }

  // ---------------------------------------------------------------------------
  // 日志
  // ---------------------------------------------------------------------------

  Future<void> addLog(
    int accountId,
    PlatformKind provider, {
    required String action,
    required bool ok,
    int? code,
    String message = '',
    Object? payload,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.insert('checkin_logs', {
      'account_id': accountId,
      'provider': provider.id,
      'action': action,
      'ok': ok ? 1 : 0,
      'code': code,
      'message': message.length > 500 ? message.substring(0, 500) : message,
      'payload_json': payload == null ? null : jsonEncodeSorted(payload),
      'created_at': now,
    });
  }

  Future<List<CheckinLog>> recentLogs({int limit = 80}) async {
    final rows = await _db.rawQuery(
      '''
      SELECT l.id, l.account_id, a.display_name, a.label, l.provider, l.action,
             l.ok, l.code, l.message, l.created_at
      FROM checkin_logs l
      LEFT JOIN accounts a ON a.id = l.account_id
      ORDER BY l.id DESC LIMIT ?
      ''',
      [limit.clamp(1, 500)],
    );
    return rows.map(CheckinLog.fromRow).toList();
  }

  // ---------------------------------------------------------------------------
  // 设置
  // ---------------------------------------------------------------------------

  Future<String?> getSetting(String key, {String? fallback}) async {
    final rows = await _db.query('settings', columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? fallback : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.rawInsert(
      'INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}
