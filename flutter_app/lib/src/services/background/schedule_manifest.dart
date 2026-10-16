import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../util/app_paths.dart';

/// 一条「已注册到系统」的计划任务记录。
class ScheduleEntry {
  const ScheduleEntry({required this.accountId, required this.time, required this.label});

  final int accountId;

  /// `HH:MM`
  final String time;
  final String label;

  Map<String, Object?> toJson() => {'accountId': accountId, 'time': time, 'label': label};

  static ScheduleEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['accountId'];
    final time = raw['time'];
    if (id is! int || time is! String) return null;
    return ScheduleEntry(accountId: id, time: time, label: raw['label']?.toString() ?? '');
  }
}

/// 本应用写下的系统计划任务清单。
///
/// 系统调度器的存储格式差异很大（systemd 单元文件、launchd plist、
/// schtasks 数据库、WorkManager），且查询接口在部分平台上需要解析本地化文本，
/// 因此这里保留一份权威清单：写入由本应用负责，运行与否仍以系统查询为准。
///
/// 目录是懒解析的——构造清单不会触碰文件系统，避免在没有 Flutter 插件
/// 环境（例如纯单元测试）时抛错。
class ScheduleManifest {
  const ScheduleManifest({Directory? directory}) : _directory = directory;

  final Directory? _directory;

  Future<File> _resolve() async {
    final dir = _directory ?? await AppPaths.dataDir();
    return File(p.join(dir.path, 'background-schedule.json'));
  }

  Future<List<ScheduleEntry>> read() async {
    try {
      final file = await _resolve();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return decoded.map(ScheduleEntry.fromJson).whereType<ScheduleEntry>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> write(List<ScheduleEntry> entries) async {
    final file = await _resolve();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode([for (final entry in entries) entry.toJson()]));
  }
}
