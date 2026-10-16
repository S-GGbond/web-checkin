import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_database.dart';
import '../models/account.dart';
import '../models/checkin_log.dart';
import '../models/login_session.dart';
import '../background_entry.dart';
import '../services/background/android_permissions.dart';
import '../services/background/background_scheduler.dart';
import '../services/background/scheduler_factory.dart';
import '../services/checkin_runner.dart';
import '../services/http_json.dart';
import '../services/scheduler.dart';

/// 应用状态中枢：持有数据库、平台服务、调度器，并向界面暴露可观察状态。
class AppState extends ChangeNotifier {
  late final AppDatabase db;
  late final CheckinRunner runner;
  late final CheckinScheduler scheduler;

  /// 系统级后台定时（systemd / launchd / schtasks / WorkManager）。
  late final BackgroundScheduler background;
  bool backgroundSyncing = false;

  BackgroundSchedulerStatus get backgroundStatus => background.status;

  /// Android 精确闹钟权限状态；null 表示当前平台不需要该权限。
  bool? exactAlarmGranted;

  /// 是否需要引导用户去开启精确闹钟权限（未授权且平台是 Android）。
  bool get needsExactAlarmPermission => Platform.isAndroid && exactAlarmGranted == false;

  final List<Account> accounts = [];
  final List<CheckinLog> logs = [];
  final List<LoginSession> activeLogins = [];

  bool initialized = false;
  bool refreshing = false;
  String? fatalError;

  final Set<int> _busyAccounts = {};
  bool _schedulerReady = false;

  bool isBusy(int accountId) => _busyAccounts.contains(accountId);

  bool get anyBusy => _busyAccounts.isNotEmpty;

  int get totalAccounts => accounts.length;
  int get enabledAccounts => accounts.where((a) => a.enabled).length;
  int get checkedInToday => accounts.where((a) => a.checkedInToday).length;

  List<Account> get traeAccounts => accounts.where((a) => a.provider == PlatformKind.trae).toList();
  List<Account> get workbuddyAccounts => accounts.where((a) => a.provider == PlatformKind.workbuddy).toList();

  /// [database] 仅用于测试注入内存库；[startScheduler]/[refreshOnStart]
  /// 让测试可以跳过计时器与网络请求。
  Future<void> init({
    AppDatabase? database,
    bool startScheduler = true,
    bool refreshOnStart = true,
    bool syncBackground = true,
  }) async {
    if (initialized) return;
    try {
      db = database ?? await AppDatabase.open();
      runner = CheckinRunner(db);
      scheduler = CheckinScheduler(db: db, runCheckin: _scheduledCheckin);
      background = createBackgroundScheduler();
      _schedulerReady = true;
      await _reload();
      initialized = true;
      if (startScheduler) scheduler.start();
      if (syncBackground) {
        unawaited(syncBackgroundSchedule());
        unawaited(refreshExactAlarmPermission());
      }
      if (refreshOnStart) unawaited(refreshAll());
    } catch (error) {
      fatalError = error.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    accounts
      ..clear()
      ..addAll(await db.listAccounts());
    final recent = await db.recentLogs();
    logs
      ..clear()
      ..addAll(recent);
  }

  Future<void> reload({bool notify = true}) async {
    await _reload();
    if (notify) notifyListeners();
  }

  void _setBusy(int accountId, bool busy) {
    if (busy) {
      _busyAccounts.add(accountId);
    } else {
      _busyAccounts.remove(accountId);
    }
  }

  // ---------------------------------------------------------------------------
  // 状态刷新
  // ---------------------------------------------------------------------------

  Future<void> refreshAll() async {
    if (refreshing || accounts.isEmpty) {
      await reload();
      return;
    }
    refreshing = true;
    notifyListeners();
    for (final row in await db.listAccountRows()) {
      try {
        await runner.status(row);
      } catch (_) {
        // 单个账号失败不影响其他账号，失败信息已写入日志。
      }
    }
    refreshing = false;
    await reload();
  }

  Future<String?> refreshAccount(int accountId) async {
    final row = await db.getAccountRow(accountId);
    if (row == null) return '账号不存在';
    _setBusy(accountId, true);
    notifyListeners();
    try {
      await runner.status(row);
      await reload();
      return null;
    } catch (error) {
      await reload();
      return _message(error);
    } finally {
      _setBusy(accountId, false);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 签到
  // ---------------------------------------------------------------------------

  Future<void> _scheduledCheckin(Map<String, Object?> row) async {
    final result = await runner.checkin(row);
    if (result['ok'] != true) {
      throw ApiException(result['message']?.toString() ?? '签到失败');
    }
  }

  Future<String?> checkinAccount(int accountId) async {
    final row = await db.getAccountRow(accountId);
    if (row == null) return '账号不存在';
    _setBusy(accountId, true);
    notifyListeners();
    try {
      final result = await runner.checkin(row);
      await reload();
      return result['ok'] == true ? null : result['message']?.toString();
    } catch (error) {
      await reload();
      return _message(error);
    } finally {
      _setBusy(accountId, false);
      notifyListeners();
    }
  }

  Future<String?> checkinAllEnabled() async {
    final rows = await db.listAccountRows(enabledOnly: true);
    if (rows.isEmpty) return '没有启用的账号';
    var failed = 0;
    for (final row in rows) {
      final id = row['id'] as int;
      _setBusy(id, true);
      notifyListeners();
      try {
        final result = await runner.checkin(row);
        if (result['ok'] != true) failed++;
      } catch (_) {
        failed++;
      } finally {
        _setBusy(id, false);
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    await reload();
    notifyListeners();
    return failed == 0 ? null : '$failed 个账号签到失败';
  }

  // ---------------------------------------------------------------------------
  // 账号管理
  // ---------------------------------------------------------------------------

  Future<void> setEnabled(int accountId, bool enabled) async {
    await db.setEnabled(accountId, enabled);
    await reload();
    await syncBackgroundSchedule();
  }

  /// 让系统中的计划任务与当前账号配置保持一致。
  Future<String?> syncBackgroundSchedule() async {
    if (backgroundSyncing || !initialized) return null;
    backgroundSyncing = true;
    notifyListeners();
    try {
      final error = await background.sync(backgroundTargets(await db.listAccounts()));
      await background.refresh();
      return error;
    } finally {
      backgroundSyncing = false;
      notifyListeners();
    }
  }

  /// 重新读取 Android 精确闹钟权限（用户从系统设置返回时调用）。
  Future<void> refreshExactAlarmPermission() async {
    if (!Platform.isAndroid) {
      exactAlarmGranted = null;
      return;
    }
    final granted = await AndroidPermissions.canScheduleExactAlarms();
    if (granted == exactAlarmGranted) return;
    exactAlarmGranted = granted;
    // 权限变化会影响闹钟是否精确，重新同步一次。
    if (granted) await syncBackgroundSchedule();
    notifyListeners();
  }

  /// 打开系统「闹钟和提醒」设置页。
  Future<bool> openExactAlarmSettings() => AndroidPermissions.openExactAlarmSettings();

  /// 移除本应用注册的全部系统计划任务。
  Future<String?> uninstallBackgroundSchedule() async {
    final error = await background.uninstallAll();
    await background.refresh();
    notifyListeners();
    return error;
  }

  Future<void> setSchedule(int accountId, {required bool enabled, required String time}) async {
    final row = await db.getAccountRow(accountId);
    if (row != null && (row['schedule_time'] as String?) != time) {
      scheduler.resetRetry(accountId);
    }
    await db.updateSchedule(accountId, enabled: enabled, time: time);
    await reload();
    await syncBackgroundSchedule();
  }

  Future<void> deleteAccount(int accountId) async {
    scheduler.forget(accountId);
    await db.deleteAccount(accountId);
    await reload();
    await syncBackgroundSchedule();
  }

  // ---------------------------------------------------------------------------
  // 登录
  // ---------------------------------------------------------------------------

  Future<LoginSession> startLogin(PlatformKind provider, {String label = ''}) async {
    final session = provider == PlatformKind.trae
        ? await runner.trae.startLogin(label: label, onUpdate: _onLoginUpdate)
        : await runner.workbuddy.startLogin(label: label, onUpdate: _onLoginUpdate);
    activeLogins.add(session);
    notifyListeners();
    await _openExternal(session);
    return session;
  }

  void _onLoginUpdate() {
    final finished = activeLogins.where((s) => s.isTerminal).toList();
    if (finished.isNotEmpty) {
      unawaited(reload().then((_) => syncBackgroundSchedule()));
    }
    notifyListeners();
  }

  void dismissLogin(LoginSession session) {
    activeLogins.remove(session);
    notifyListeners();
  }

  Future<bool> reopenLogin(LoginSession session) => _openExternal(session);

  Future<bool> _openExternal(LoginSession session) async {
    try {
      return await launchUrl(Uri.parse(session.authUrl), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 导入 / 维护
  // ---------------------------------------------------------------------------

  Future<String?> importTraeFromDesktop() async {
    try {
      final ids = await runner.trae.importFromDesktop();
      await reload();
      if (ids.isEmpty) return '未在本机 Trae 客户端中找到登录态';
      return null;
    } catch (error) {
      return _message(error);
    }
  }

  static String _message(Object error) {
    if (error is ApiException) return error.message;
    return error.toString();
  }

  @override
  void dispose() {
    if (_schedulerReady) scheduler.stop();
    if (initialized) background.dispose();
    super.dispose();
  }
}
