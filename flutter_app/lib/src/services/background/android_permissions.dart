import 'dart:io';

import 'package:flutter/services.dart';

/// Android 精确闹钟权限（`SCHEDULE_EXACT_ALARM`）的查询与申请。
///
/// Android 14 起该权限默认被拒绝，必须在系统设置里由用户手动开启；
/// 原生侧实现见 `android/app/src/main/kotlin/.../MainActivity.kt`。
class AndroidPermissions {
  AndroidPermissions._();

  static const MethodChannel _channel = MethodChannel('dev.checkinhub/permissions');

  /// 是否已允许精确闹钟。非 Android 平台恒为 true。
  static Future<bool> canScheduleExactAlarms() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('canScheduleExactAlarms') ?? false;
    } on PlatformException {
      // 拿不到状态时按「未授权」处理，调用方会自动退化成非精确闹钟。
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开系统的「闹钟和提醒」设置页，返回是否成功拉起。
  static Future<bool> openExactAlarmSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openExactAlarmSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
