package com.gokadzev.musify

import android.app.ActivityOptions
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

object PlaylistAlarmScheduler {
  const val ACTION_FIRE = "com.gokadzev.musify.playlist_alarm.FIRE"
  const val ACTION_SHOW = "com.gokadzev.musify.playlist_alarm.SHOW"
  const val EXTRA_ALARM_ID = "playlist_alarm_id"

  private const val PREFERENCES = "musify_playlist_alarms"
  private const val DEFINITIONS_KEY = "definitions"

  data class AlarmDefinition(
    val id: String,
    val hour: Int,
    val minute: Int,
    val weekdays: Set<Int>,
  )

  fun canScheduleExactAlarms(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
    val manager = context.getSystemService(AlarmManager::class.java)
    return manager?.canScheduleExactAlarms() == true
  }

  fun sync(context: Context, rawAlarms: List<*>): Boolean {
    val manager = context.getSystemService(AlarmManager::class.java) ?: return false
    read(context).forEach { manager.cancel(operation(context, it.id)) }

    val alarms = rawAlarms.mapNotNull(::parse)
    write(context, alarms)
    if (!canScheduleExactAlarms(context)) return false

    return try {
      alarms.forEach { schedule(context, manager, it) }
      true
    } catch (_: SecurityException) {
      false
    }
  }

  fun rescheduleStored(context: Context) {
    if (!canScheduleExactAlarms(context)) return
    val manager = context.getSystemService(AlarmManager::class.java) ?: return
    try {
      read(context).forEach { schedule(context, manager, it) }
    } catch (_: SecurityException) {
      // Permission may have been revoked between the check and scheduling.
    }
  }

  fun handleFired(context: Context, alarmId: String) {
    val alarms = read(context)
    val fired = alarms.firstOrNull { it.id == alarmId } ?: return
    if (fired.weekdays.isEmpty()) {
      write(context, alarms.filterNot { it.id == alarmId })
      return
    }
    if (canScheduleExactAlarms(context)) {
      val manager = context.getSystemService(AlarmManager::class.java) ?: return
      try {
        schedule(context, manager, fired)
      } catch (_: SecurityException) {
        // It will be restored after the user grants exact-alarm access again.
      }
    }
  }

  private fun schedule(context: Context, manager: AlarmManager, alarm: AlarmDefinition) {
    val triggerAt = nextTrigger(alarm, System.currentTimeMillis())
    val info = AlarmManager.AlarmClockInfo(triggerAt, showIntent(context))
    manager.setAlarmClock(info, operation(context, alarm.id))
  }

  private fun nextTrigger(alarm: AlarmDefinition, nowMillis: Long): Long {
    val candidate = Calendar.getInstance().apply {
      timeInMillis = nowMillis
      set(Calendar.HOUR_OF_DAY, alarm.hour)
      set(Calendar.MINUTE, alarm.minute)
      set(Calendar.SECOND, 0)
      set(Calendar.MILLISECOND, 0)
    }

    if (alarm.weekdays.isEmpty()) {
      if (candidate.timeInMillis <= nowMillis) candidate.add(Calendar.DAY_OF_YEAR, 1)
      return candidate.timeInMillis
    }

    repeat(8) { offset ->
      val occurrence = candidate.clone() as Calendar
      occurrence.add(Calendar.DAY_OF_YEAR, offset)
      if (
        alarm.weekdays.contains(isoWeekday(occurrence)) &&
        occurrence.timeInMillis > nowMillis
      ) {
        return occurrence.timeInMillis
      }
    }
    candidate.add(Calendar.DAY_OF_YEAR, 1)
    return candidate.timeInMillis
  }

  private fun isoWeekday(calendar: Calendar): Int =
    ((calendar.get(Calendar.DAY_OF_WEEK) + 5) % 7) + 1

  private fun operation(context: Context, alarmId: String): PendingIntent {
    val intent = Intent(context, MainActivity::class.java).apply {
      action = ACTION_FIRE
      data = Uri.parse("musify://playlist-alarm/$alarmId")
      putExtra(EXTRA_ALARM_ID, alarmId)
      flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }
    return PendingIntent.getActivity(
      context,
      alarmId.hashCode(),
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      backgroundActivityOptions(),
    )
  }

  private fun showIntent(context: Context): PendingIntent {
    val intent = Intent(context, MainActivity::class.java).apply {
      action = ACTION_SHOW
      flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }
    return PendingIntent.getActivity(
      context,
      0x4D5553,
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      backgroundActivityOptions(),
    )
  }

  private fun backgroundActivityOptions() = ActivityOptions.makeBasic().apply {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
      pendingIntentCreatorBackgroundActivityStartMode =
        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
      pendingIntentCreatorBackgroundActivityStartMode =
        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
    }
  }.toBundle()

  private fun parse(raw: Any?): AlarmDefinition? {
    if (raw !is Map<*, *>) return null
    val id = raw["id"]?.toString()?.takeIf { it.isNotBlank() } ?: return null
    val hour = (raw["hour"] as? Number)?.toInt() ?: return null
    val minute = (raw["minute"] as? Number)?.toInt() ?: return null
    if (hour !in 0..23 || minute !in 0..59) return null
    val weekdays = (raw["weekdays"] as? List<*>)
      .orEmpty()
      .mapNotNull { (it as? Number)?.toInt() }
      .filter { it in 1..7 }
      .toSet()
    return AlarmDefinition(id, hour, minute, weekdays)
  }

  private fun read(context: Context): List<AlarmDefinition> {
    val value = context
      .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .getString(DEFINITIONS_KEY, null) ?: return emptyList()
    return try {
      val json = JSONArray(value)
      buildList {
        for (index in 0 until json.length()) {
          val item = json.optJSONObject(index) ?: continue
          val id = item.optString("id").takeIf { it.isNotBlank() } ?: continue
          val hour = item.optInt("hour", -1)
          val minute = item.optInt("minute", -1)
          if (hour !in 0..23 || minute !in 0..59) continue
          val daysJson = item.optJSONArray("weekdays") ?: JSONArray()
          val days = buildSet {
            for (dayIndex in 0 until daysJson.length()) {
              val day = daysJson.optInt(dayIndex, -1)
              if (day in 1..7) add(day)
            }
          }
          add(AlarmDefinition(id, hour, minute, days))
        }
      }
    } catch (_: Exception) {
      emptyList()
    }
  }

  private fun write(context: Context, alarms: List<AlarmDefinition>) {
    val json = JSONArray()
    alarms.forEach { alarm ->
      json.put(
        JSONObject().apply {
          put("id", alarm.id)
          put("hour", alarm.hour)
          put("minute", alarm.minute)
          put("weekdays", JSONArray(alarm.weekdays.sorted()))
        },
      )
    }
    context
      .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .edit()
      .putString(DEFINITIONS_KEY, json.toString())
      .apply()
  }
}
