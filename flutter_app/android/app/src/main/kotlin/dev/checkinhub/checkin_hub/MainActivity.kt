package dev.checkinhub.checkin_hub

import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 暴露「精确闹钟」权限的查询与申请入口。
 *
 * android_alarm_manager_plus 自身不处理 SCHEDULE_EXACT_ALARM，而 Android 14
 * 起该权限默认被拒绝，必须由用户手动开启，因此这里用一个很薄的 MethodChannel
 * 把系统设置页拉起来，避免为此再引入一个权限插件。
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "dev.checkinhub/permissions"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canScheduleExactAlarms" -> result.success(canScheduleExactAlarms())
                    "openExactAlarmSettings" -> {
                        openExactAlarmSettings()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Android 12 以下没有该权限概念，恒为可用。 */
    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        return alarmManager.canScheduleExactAlarms()
    }

    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val request = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:$packageName")
        }
        try {
            startActivity(request)
        } catch (_: Exception) {
            // 部分 ROM 没有这个设置页，退回应用详情页让用户手动开启。
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        }
    }
}
