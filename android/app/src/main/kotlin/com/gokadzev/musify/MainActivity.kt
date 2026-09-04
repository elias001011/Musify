package com.gokadzev.musify

import android.app.AlarmManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.view.WindowCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
  private var alarmChannel: MethodChannel? = null
  private var initialAlarmConsumed = false

  override fun onCreate(savedInstanceState: Bundle?) {
    WindowCompat.setDecorFitsSystemWindows(window, false)

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
    }

    super.onCreate(savedInstanceState)
    handleNativeAlarm(intent)
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    alarmChannel = MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      CHANNEL_NAME,
    ).also { channel ->
      channel.setMethodCallHandler { call, result ->
        when (call.method) {
          "canScheduleExactAlarms" -> result.success(
            PlaylistAlarmScheduler.canScheduleExactAlarms(applicationContext),
          )
          "requestExactAlarmPermission" -> {
            requestExactAlarmPermission()
            result.success(null)
          }
          "syncAlarms" -> {
            val arguments = call.arguments as? Map<*, *>
            val alarms = arguments?.get("alarms") as? List<*> ?: emptyList<Any>()
            result.success(PlaylistAlarmScheduler.sync(applicationContext, alarms))
          }
          "getInitialAlarmId" -> {
            val alarmId = if (!initialAlarmConsumed) alarmId(intent) else null
            initialAlarmConsumed = true
            result.success(alarmId)
          }
          else -> result.notImplemented()
        }
      }
    }
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    handleNativeAlarm(intent)
    alarmId(intent)?.let { alarmChannel?.invokeMethod("alarmFired", it) }
  }

  private fun handleNativeAlarm(intent: Intent?) {
    val id = alarmId(intent) ?: return
    PlaylistAlarmScheduler.handleFired(applicationContext, id)
  }

  private fun alarmId(intent: Intent?): String? {
    if (intent?.action != PlaylistAlarmScheduler.ACTION_FIRE) return null
    return intent.getStringExtra(PlaylistAlarmScheduler.EXTRA_ALARM_ID)
  }

  private fun requestExactAlarmPermission() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    val alarmManager = getSystemService(AlarmManager::class.java)
    if (alarmManager?.canScheduleExactAlarms() == true) return
    startActivity(
      Intent(
        Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
        Uri.parse("package:$packageName"),
      ),
    )
  }

  companion object {
    private const val CHANNEL_NAME = "com.gokadzev.musify/playlist_alarm"
  }
}
