import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
import '../services/qoder/qoder_desktop.dart';
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

  /// Qoder 桌面端当前登录的 userId（Linux safeStorage 读取）。
  String? qoderActiveUid;

  bool get desktopSwitchSupported => DesktopSwitchService.supported;

  /// 走 DesktopSwitchService 的平台；Qoder 的登录态格式不同，单独处理。
  static const List<PlatformKind> _desktopProviders = [
    PlatformKind.workbuddy,
    PlatformKind.trae,
  ];

  DesktopClientInfo? desktopClient(PlatformKind provider) => desktopClients[provider];

  /// 客户端当前登录的账号 id；未安装或未登录时为 null。
  String? desktopActiveId(PlatformKind provider) =>
      provider == PlatformKind.qoder
          ? qoderActiveUid
          : desktopClients[provider]?.activeExternalId;

  /// 该平台的客户端登录态在当前系统上是否可探测/切换。
  bool desktopClientSupported(PlatformKind provider) =>
      desktopSwitchSupported &&
      (provider != PlatformKind.qoder || QoderDesktopAuth.supported);

  /// 该平台是否支持把账号写回本机客户端。
  bool canSwitchClient(PlatformKind provider) {
    if (!desktopSwitchSupported) return false;
    if (provider == PlatformKind.qoder) {
      return QoderDesktopAuth.supported &&
          (desktopClients[provider]?.canSwitch ??
              QoderDesktopAuth.authFile() != null);
    }
    return desktopClients[provider]?.canSwitch ?? false;
  }

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

  /// 上次成功刷新账号状态的时间（持久化，重启后仍生效）。
  DateTime? lastStatusRefresh;

  /// 状态自动刷新的最短间隔：进应用不必每次都打一遍接口。
  static const statusRefreshTtl = Duration(minutes: 10);

  /// 外观：跟随系统 / 浅色 / 深色，持久化在 settings 表。
  ThemeMode themeMode = ThemeMode.system;

  Future<void> setThemeMode(ThemeMode mode) async {
    if (themeMode == mode) return;
    themeMode = mode;
    notifyListeners();
    try {
      await db.setSetting('theme_mode', mode.name);
    } catch (_) {
      // 写入失败不影响本次会话。
    }
  }
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
      // 先让界面出来：客户端探测要起 python / 扫安装目录，不能挡首屏。
      notifyListeners();
      if (syncBackground) {
        unawaited(syncBackgroundSchedule());
        unawaited(refreshExactAlarmPermission());
      }
      if (desktopSwitchSupported) {
        unawaited(_initDesktop(importDesktopAccounts));
      }
      if (refreshOnStart) unawaited(refreshAll());
    } catch (error) {
      fatalError = error.toString();
    } finally {
      notifyListeners();
    }
  }

  /// 桌面端启动时的后台准备：迁移旧账号库 + 探测各客户端登录态。
  Future<void> _initDesktop(bool importAccounts) async {
    try {
      if (importAccounts) {
        final imported = await runner.qoder.importLegacyAccounts();
        if (imported > 0) await _reload();
      }
      await refreshDesktopClients(importAccounts: importAccounts);
    } catch (_) {
      // 探测失败不影响主流程，界面保持「未检测到」即可。
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
    final stamp = int.tryParse(await db.getSetting('status_refreshed_at') ?? '');
    if (stamp != null) {
      lastStatusRefresh = DateTime.fromMillisecondsSinceEpoch(stamp);
    }
    final stored = await db.getSetting('theme_mode');
    themeMode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
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

  /// 距上次刷新是否已超过 [statusRefreshTtl]（进应用时据此决定要不要打接口）。
  bool get statusRefreshDue {
    final last = lastStatusRefresh;
    return last == null ||
        DateTime.now().difference(last) >= statusRefreshTtl;
  }

  /// 刷新所有账号状态。
  ///
  /// [force] 为假时，距上次成功刷新不到 [statusRefreshTtl] 就直接用库里的值，
  /// 避免每次进界面都先打一轮接口（十几秒看不到内容）。
  Future<void> refreshAll({bool force = false}) async {
    if (refreshing || accounts.isEmpty) {
      await reload();
      return;
    }
    if (!force && !statusRefreshDue) {
      await reload();
      return;
    }
    refreshing = true;
    notifyListeners();
    final rows = await db.listAccountRows();
    // 分批发（并发 3）：串行刷 10 个账号的状态，首屏要等十几秒。
    const batch = 3;
    for (var start = 0; start < rows.length; start += batch) {
      await Future.wait(
        rows.skip(start).take(batch).map((row) async {
          try {
            await runner.status(row);
          } catch (_) {
            // 单个账号失败不影响其他账号，失败信息已写入日志。
          }
        }),
      );
    }
    refreshing = false;
    await _markStatusRefreshed();
    await reload();
  }

  /// 记录最近一次状态刷新时间（供下次进入界面判断是否需要重刷）。
  Future<void> _markStatusRefreshed() async {
    lastStatusRefresh = DateTime.now();
    try {
      await db.setSetting(
        'status_refreshed_at',
        lastStatusRefresh!.millisecondsSinceEpoch.toString(),
      );
    } catch (_) {
      // 写不进去只影响下次是否重刷，不影响本次结果。
    }
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
    // 三个平台并行探测：串行时启动/切号后要多等一倍以上。
    await Future.wait([
      _probeQoder(refreshActive: refreshExecutable),
      for (final provider in _desktopProviders)
        () async {
          try {
            desktopClients[provider] = await desktopSwitch.inspect(
              provider,
              refreshExecutable: refreshExecutable,
            );
          } catch (_) {
            // 探测失败也放一个空状态：界面显示「未检测到登录态」，不能一直转圈。
            desktopClients[provider] = DesktopClientInfo(
              provider: provider,
              authFiles: const [],
              executable: null,
              activeExternalId: null,
            );
          }
        }(),
    ]);
    if (importAccounts) await _importDesktopAccounts();
    notifyListeners();
  }

  /// Qoder 不走 DesktopSwitchService：登录态是 safeStorage 容器，单独读取。
  Future<void> _probeQoder({bool refreshActive = false}) async {
    if (!QoderDesktopAuth.supported) {
      // 非 Linux 平台没有 Qoder 换号能力：给一个空状态，界面据此整块隐藏。
      desktopClients[PlatformKind.qoder] = const DesktopClientInfo(
        provider: PlatformKind.qoder,
        authFiles: [],
        executable: null,
        activeExternalId: null,
      );
      return;
    }
    final authFile = QoderDesktopAuth.authFile();
    var uid = '';
    try {
      uid = await QoderDesktopAuth.currentUid(refresh: refreshActive);
    } catch (_) {
      // 钥匙环不可用：仍把文件状态报出去，界面显示「客户端未登录」。
    }
    qoderActiveUid = uid.isEmpty ? null : uid;
    desktopClients[PlatformKind.qoder] = DesktopClientInfo(
      provider: PlatformKind.qoder,
      authFiles: authFile == null ? const [] : [authFile],
      executable: QoderDesktopAuth.executablePath(),
      activeExternalId: qoderActiveUid,
    );
  }

  Future<void> _importDesktopAccounts() async {
    if (!initialized) return;
    final rows = await db.listAccountRows();
    final known = <String>{for (final row in rows) '${row['provider']}:${row['external_id']}'};
    // 读取各客户端登录态可以并行（都是本地文件解析）。
    final drafts = await Future.wait([
      for (final provider in _desktopProviders) _readDraft(provider),
    ]);
    var imported = 0;
    for (final draft in drafts) {
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

  Future<DesktopAccountDraft?> _readDraft(PlatformKind provider) async {
    try {
      return await desktopSwitch.readCurrentAccount(provider);
    } catch (_) {
      return null;
    }
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
      if (provider == PlatformKind.qoder) {
        _desktopSwitchPhase = '正在关闭 Qoder 客户端…';
        notifyListeners();
        // stop() 自己会轮询退出（TERM → KILL），关掉后再写盘；
        // 之前只等 600ms 就报「仍在运行」，客户端其实已经关了。
        if (!await QoderDesktopAuth.stop()) {
          throw const QoderDesktopException('Qoder 没有退出，请手动关闭后再切换');
        }
        _desktopSwitchPhase = '正在写入 Qoder 登录态…';
        notifyListeners();
        await runner.qoder.switchDesktop(row);
        // 刚写进去的就是这个账号，不必再起 python 读一遍文件。
        qoderActiveUid = row['external_id']?.toString();
        desktopClients[PlatformKind.qoder] = DesktopClientInfo(
          provider: PlatformKind.qoder,
          authFiles: [QoderDesktopAuth.authFile() ?? ''].where((path) => path.isNotEmpty).toList(),
          executable: QoderDesktopAuth.executablePath(),
          activeExternalId: qoderActiveUid,
        );
        await QoderDesktopAuth.launch();
        const result = DesktopSwitchResult(ok: true, message: '已切换，Qoder 正在重启');
        await db.addLog(
          accountId,
          provider,
          action: 'switch',
          ok: true,
          message: result.message,
        );
        await reload(notify: false);
        return result;
      }
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
    final session = switch (provider) {
      PlatformKind.trae =>
        await runner.trae.startLogin(label: label, onUpdate: _onLoginUpdate),
      PlatformKind.workbuddy =>
        await runner.workbuddy.startLogin(label: label, onUpdate: _onLoginUpdate),
      PlatformKind.qoder =>
        await runner.qoder.startLogin(label: label, onUpdate: _onLoginUpdate),
    };
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
