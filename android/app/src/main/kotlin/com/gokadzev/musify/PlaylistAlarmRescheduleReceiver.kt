package com.gokadzev.musify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class PlaylistAlarmRescheduleReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    PlaylistAlarmScheduler.rescheduleStored(context.applicationContext)
  }
}
