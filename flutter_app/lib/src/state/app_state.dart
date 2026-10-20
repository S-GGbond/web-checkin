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
import '../services/account_export.dart';
import '../services/checkin_runner.dart';
import '../services/desktop/desktop_switch_service.dart';
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

  /// 桌面客户端登录态切换。移动端不支持，界面上不会出现入口。
  final DesktopSwitchService desktopSwitch = DesktopSwitchService();

  /// 各平台客户端的探测结果（含当前登录的账号 id）。
  final Map<PlatformKind, DesktopClientInfo> desktopClients = {};

  bool get desktopSwitchSupported => DesktopSwitchService.supported;

  DesktopClientInfo? desktopClient(PlatformKind provider) => desktopClients[provider];

  /// 客户端当前登录的账号 id；未安装或未登录时为 null。
  String? desktopActiveId(PlatformKind provider) => desktopClients[provider]?.activeExternalId;

  bool isDesktopActive(Account account) => desktopActiveId(account.provider) == account.externalId;

  /// 切换进行中的阶段提示（例如「正在关闭 Trae 客户端…」）。
  String? _desktopSwitchPhase;
  PlatformKind? _desktopSwitchingProvider;

  String? desktopPhase(PlatformKind provider) =>
      _desktopSwitchingProvider == provider ? _desktopSwitchPhase : null;

  bool get desktopSwitching => _desktopSwitchingProvider != null;

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
    bool importDesktopAccounts = true,
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
      if (desktopSwitchSupported) {
        await refreshDesktopClients(importAccounts: importDesktopAccounts);
      }
      if (refreshOnStart) unawaited(refreshAll());
    } catch (error) {
      fatalError = error.toString();
    } finally {
      notifyListeners();
    }
  }

  /// 导出全部账号（含登录态）为 JSON；[outputPath] 不传则写到用户主目录。
  Future<AccountExportResult> exportAccounts({String? outputPath}) async {
    final rows = await db.listAccountRows();
    return AccountExporter.exportJson(rows: rows, outputPath: outputPath);
  }

  /// 从导出的 JSON 恢复账号（同 provider + 账号 id 覆盖登录态）。
  Future<AccountImportResult> importAccounts({required String path}) async {
    final result = await AccountExporter.importJson(path: path, db: db);
    await reload();
    return result;
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
  // 桌面客户端登录态切换（仅 Windows / Linux / macOS）
  // ---------------------------------------------------------------------------

  /// 重新探测本机客户端的位置与当前登录账号。
  ///
  /// [refreshExecutable] 仅在用户主动「重新探测」时为真（会重新搜索安装目录）；
  /// [importAccounts] 为真时，把客户端里**当前登录**、但账号库还没有的账号自动收进来。
  Future<void> refreshDesktopClients({bool importAccounts = true, bool refreshExecutable = false}) async {
    if (!desktopSwitchSupported) return;
    for (final provider in PlatformKind.values) {
      desktopClients[provider] = await desktopSwitch.inspect(
        provider,
        refreshExecutable: refreshExecutable,
      );
    }
    if (importAccounts) await _importDesktopAccounts();
    notifyListeners();
  }

  Future<void> _importDesktopAccounts() async {
    if (!initialized) return;
    final rows = await db.listAccountRows();
    final known = <String>{for (final row in rows) '${row['provider']}:${row['external_id']}'};
    var imported = 0;
    for (final provider in PlatformKind.values) {
      final draft = await desktopSwitch.readCurrentAccount(provider);
      if (draft == null || known.contains(draft.key)) continue;
      final id = await db.upsertAccount(
        provider: draft.provider,
        externalId: draft.externalId,
        displayName: draft.displayName,
        endpoint: draft.endpoint,
        credential: draft.credential,
      );
      await db.addLog(
        id,
        draft.provider,
        action: 'import',
        ok: true,
        message: '从本机客户端自动检测到该账号',
      );
      known.add(draft.key);
      imported++;
    }
    if (imported > 0) await _reload();
  }

  /// 把某个账号的登录态写回桌面客户端，随后自动重启客户端。
  ///
  /// 移动端没有桌面客户端可操作，直接拒绝（界面上入口也不会渲染）。
  Future<DesktopSwitchResult> switchDesktopAccount(int accountId) async {
    if (!desktopSwitchSupported) {
      return const DesktopSwitchResult(ok: false, message: '手机端无法切换桌面客户端登录态');
    }
    final row = await db.getAccountRow(accountId);
    if (row == null) return const DesktopSwitchResult(ok: false, message: '账号不存在');
    final provider = PlatformKind.fromId(row['provider'] as String);

    _setBusy(accountId, true);
    _desktopSwitchingProvider = provider;
    _desktopSwitchPhase = '正在关闭 ${provider.label} 客户端…';
    notifyListeners();
    try {
      final result = await desktopSwitch.switchTo(
        provider: provider,
        credential: row['credential'] as String,
        displayName: (row['display_name'] as String?) ?? '',
        onPhase: (phase) {
          _desktopSwitchPhase = phase;
          notifyListeners();
        },
      );
      await db.addLog(
        accountId,
        provider,
        action: 'switch',
        ok: result.ok,
        message: result.message,
      );
      await reload(notify: false);
      // 切换成功时客户端当前账号就是我们刚写进去的那个，直接更新状态；
      // 不再重跑探测 + 自动导入，避免切完还要多等一轮文件/目录扫描。
      if (result.ok) {
        final current = desktopClients[provider];
        desktopClients[provider] = DesktopClientInfo(
          provider: provider,
          authFiles: current?.authFiles ?? const [],
          executable: current?.executable,
          activeExternalId: row['external_id'] as String?,
        );
      }
      return result;
    } catch (error) {
      final result = DesktopSwitchResult(ok: false, message: _message(error));
      await db.addLog(accountId, provider, action: 'switch', ok: false, message: result.message);
      await reload();
      return result;
    } finally {
      _setBusy(accountId, false);
      _desktopSwitchingProvider = null;
      _desktopSwitchPhase = null;
      notifyListeners();
    }
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
