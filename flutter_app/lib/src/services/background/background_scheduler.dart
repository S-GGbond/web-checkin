import 'dart:io';

import '../../background_entry.dart';

/// 系统级后台定时的能力说明与安装状态。
class BackgroundSchedulerStatus {
  const BackgroundSchedulerStatus({
    required this.mechanism,
    required this.available,
    required this.executablePath,
    this.note,
    this.installed = const {},
    this.lastError,
  });

  /// 中文机制名，例如「systemd 用户定时器」。
  final String mechanism;

  /// 当前平台是否支持系统级定时。
  final bool available;

  /// 系统调度器将要唤起的可执行文件。
  final String executablePath;

  /// 能力限制说明（例如 Android 的 Doze 延迟）。
  final String? note;

  /// accountId → 已安装的计划时间。
  final Map<int, String> installed;

  final String? lastError;

  int get installedCount => installed.length;
}

/// 系统级每日定时的统一接口。
///
/// 每个实现都负责「把某账号的每日签到注册进操作系统」，使应用未运行时
/// 也能被唤起执行。
abstract class BackgroundScheduler {
  BackgroundSchedulerStatus get status;

  /// 让系统中的计划任务与 [targets] 完全一致：新增/更新时间，删除多余项。
  /// 返回错误信息，成功返回 null。
  Future<String?> sync(List<BackgroundTarget> targets);

  /// 移除本应用注册的全部系统计划任务。
  Future<String?> uninstallAll();

  /// 重新探测系统状态。
  Future<BackgroundSchedulerStatus> refresh();

  void dispose() {}

}

/// 不支持的平台：只暴露说明，不做任何事。
class UnsupportedScheduler implements BackgroundScheduler {
  UnsupportedScheduler(this.reason);

  final String reason;

  @override
  BackgroundSchedulerStatus get status => BackgroundSchedulerStatus(
        mechanism: '不支持',
        available: false,
        executablePath: Platform.resolvedExecutable,
        note: reason,
      );

  @override
  Future<BackgroundSchedulerStatus> refresh() async => status;

  @override
  Future<String?> sync(List<BackgroundTarget> targets) async => null;

  @override
  Future<String?> uninstallAll() async => null;

  @override
  void dispose() {}
}
