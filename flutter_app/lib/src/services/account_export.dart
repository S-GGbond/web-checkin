import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/app_database.dart';
import '../models/account.dart';
import '../util/app_paths.dart';

/// 账号导入失败（文件不存在 / 不是本应用的导出格式）。
class AccountImportException implements Exception {
  const AccountImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次导入的结果。
class AccountImportResult {
  const AccountImportResult({
    required this.added,
    required this.updated,
    required this.skipped,
    required this.problems,
  });

  final int added;
  final int updated;
  final int skipped;
  final List<String> problems;

  int get total => added + updated;
}

/// 账号导出的结果。
class AccountExportResult {
  const AccountExportResult({
    required this.path,
    required this.count,
    required this.sizeBytes,
  });

  final String path;
  final int count;
  final int sizeBytes;
}

/// 把账号库导出成可读的 JSON（含 WorkBuddy / Trae / Qoder 的登录态）。
///
/// 登录态是明文的：Trae 是加密容器密文，WorkBuddy 按客户端要求本身就是明文，
/// 导出文件请当敏感文件保管。导出只读账号库，不改动任何账号。
class AccountExporter {
  AccountExporter._();

  static const int formatVersion = 1;

  /// [rows] 是 accounts 表的原始行（含 credential 列）。
  static Future<AccountExportResult> exportJson({
    required List<Map<String, Object?>> rows,
    String? outputPath,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final accounts = rows.map(_account).toList();
    final payload = <String, Object?>{
      'app': 'checkin-hub',
      'format': 'accounts',
      'version': formatVersion,
      'exported_at': at.toUtc().toIso8601String(),
      'accounts': accounts,
    };

    final out = outputPath ?? defaultPath(at);
    final file = File(out);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    if (!Platform.isWindows) {
      // 含登录态，尽量只给本人可读。
      await Process.run('chmod', ['600', file.path]);
    }
    return AccountExportResult(
      path: out,
      count: accounts.length,
      sizeBytes: await file.length(),
    );
  }

  /// 从导出的 JSON 恢复账号：同 provider + 账号 id 视为同一账号，覆盖登录态。
  static Future<AccountImportResult> importJson({
    required String path,
    required AppDatabase db,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AccountImportException('文件不存在：$path');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (_) {
      throw const AccountImportException('文件不是合法的 JSON');
    }
    if (decoded is! Map || decoded['format'] != 'accounts') {
      throw const AccountImportException('不是本应用导出的账号文件（缺 format: accounts）');
    }
    final list = decoded['accounts'];
    if (list is! List) {
      throw const AccountImportException('账号文件里没有 accounts 列表');
    }

    final existing = <String, int>{};
    for (final row in await db.listAccountRows()) {
      final id = row['id'];
      if (id is int) {
        existing['${row['provider']}:${row['external_id']}'] = id;
      }
    }

    var added = 0;
    var updated = 0;
    var skipped = 0;
    final problems = <String>[];
    for (final item in list) {
      if (item is! Map) {
        skipped++;
        continue;
      }
      final providerId = item['provider']?.toString() ?? '';
      PlatformKind? provider;
      for (final kind in PlatformKind.values) {
        if (kind.id == providerId) provider = kind;
      }
      final externalId = item['externalId']?.toString() ?? '';
      final endpoint = item['endpoint']?.toString() ?? '';
      final credential = item['credential'];
      if (provider == null ||
          externalId.isEmpty ||
          endpoint.isEmpty ||
          credential == null) {
        skipped++;
        problems.add('缺少 provider / externalId / endpoint / credential');
        continue;
      }

      try {
        final id = await db.upsertAccount(
          provider: provider,
          externalId: externalId,
          displayName: item['displayName']?.toString() ?? '',
          endpoint: endpoint,
          credential: credential is String
              ? credential
              : jsonEncode(credential),
          label: item['label']?.toString() ?? '',
        );
        if (existing.containsKey('${provider.id}:$externalId')) {
          updated++;
        } else {
          added++;
        }
        final enabled = item['enabled'];
        if (enabled is bool) await db.setEnabled(id, enabled);
        final schedule = item['schedule'];
        if (schedule is Map) {
          final time = schedule['time']?.toString() ?? '';
          final enabledFlag = schedule['enabled'];
          if (time.isNotEmpty && enabledFlag is bool) {
            await db.updateSchedule(id, enabled: enabledFlag, time: time);
          }
        }
      } catch (error) {
        skipped++;
        problems.add('$externalId：$error');
      }
    }
    return AccountImportResult(
      added: added,
      updated: updated,
      skipped: skipped,
      problems: problems,
    );
  }

  static String defaultPath(DateTime at) {
    final home = AppPaths.home;
    final stamp = at
        .toIso8601String()
        .replaceAll(RegExp('[:.T-]'), '')
        .substring(0, 15);
    return p.join(home, 'checkin-accounts-$stamp.json');
  }

  static Map<String, Object?> _account(Map<String, Object?> row) {
    return <String, Object?>{
      'provider': row['provider'],
      'externalId': row['external_id'],
      'displayName': row['display_name'],
      'label': row['label'],
      'endpoint': row['endpoint'],
      'enabled': row['enabled'] == 1,
      'credential': _maybeJson(row['credential']),
      'status': _maybeJson(row['last_status']),
      'checkin': <String, Object?>{
        'at': _iso(row['last_checkin_at']),
        'ok': row['last_checkin_ok'] == 1,
        'message': row['last_checkin_message'],
      },
      'schedule': <String, Object?>{
        'time': row['schedule_time'],
        'enabled': row['schedule_enabled'] == 1,
        'lastDate': row['schedule_last_date'],
      },
      'createdAt': _iso(row['created_at']),
      'updatedAt': _iso(row['updated_at']),
    };
  }

  /// 库里的 JSON 字段原样解开；不是 JSON 就保留字符串。
  static Object? _maybeJson(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  /// 库里存的是秒级时间戳，导出成 ISO 便于人看。
  static String? _iso(Object? raw) {
    final seconds = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    ).toIso8601String();
  }
}
