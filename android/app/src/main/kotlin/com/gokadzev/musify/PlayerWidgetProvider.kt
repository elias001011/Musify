package com.gokadzev.musify

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.View
import android.widget.RemoteViews
import com.ryanheise.audioservice.AudioService
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

class PlayerWidgetProvider : HomeWidgetProvider() {
  override fun onUpdate(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetIds: IntArray,
    widgetData: SharedPreferences,
  ) {
    appWidgetIds.forEach { widgetId ->
      updateWidget(context, appWidgetManager, widgetId, widgetData)
    }
  }

  override fun onReceive(context: Context, intent: Intent) {
    super.onReceive(context, intent)
    val action = intent.action ?: return
    if (action !in playerActions) return

    controlPlayback(context.applicationContext, action, goAsync())
  }

  private fun updateWidget(
    context: Context,
    appWidgetManager: AppWidgetManager,
    widgetId: Int,
    widgetData: SharedPreferences,
  ) {
    val hasMedia = widgetData.getBoolean(KEY_HAS_MEDIA, false)
    val isPlaying = widgetData.getBoolean(KEY_IS_PLAYING, false)
    val title = widgetData.getString(KEY_TITLE, null).orEmpty().ifBlank {
      context.getString(R.string.widget_default_title)
    }
    val artist = widgetData.getString(KEY_ARTIST, null).orEmpty().ifBlank {
      context.getString(
        if (hasMedia) R.string.widget_unknown_artist else R.string.widget_resume_hint,
      )
    }
    val artwork = widgetData.getString(KEY_ARTWORK, null).orEmpty()
    val canSkipPrevious = widgetData.getBoolean(KEY_CAN_SKIP_PREVIOUS, false)
    val canSkipNext = widgetData.getBoolean(KEY_CAN_SKIP_NEXT, false)

    val views = RemoteViews(context.packageName, R.layout.musify_player_widget).apply {
      setTextViewText(R.id.widget_title, title)
      setTextViewText(R.id.widget_artist, artist)
      setImageViewResource(
        R.id.widget_play_pause,
        if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
      )
      setContentDescription(
        R.id.widget_play_pause,
        context.getString(if (isPlaying) R.string.widget_pause else R.string.widget_play),
      )
      setViewVisibility(
        R.id.widget_previous,
        if (canSkipPrevious) View.VISIBLE else View.INVISIBLE,
      )
      setViewVisibility(
        R.id.widget_next,
        if (canSkipNext) View.VISIBLE else View.INVISIBLE,
      )

      setOnClickPendingIntent(
        R.id.widget_root,
        HomeWidgetLaunchIntent.getActivity(
          context,
          com.ryanheise.audioservice.AudioServiceActivity::class.java,
          Uri.parse("musify-widget://open"),
        ),
      )
      setOnClickPendingIntent(
        R.id.widget_previous,
        playbackPendingIntent(context, ACTION_PREVIOUS, widgetId),
      )
      setOnClickPendingIntent(
        R.id.widget_play_pause,
        playbackPendingIntent(context, ACTION_PLAY_PAUSE, widgetId),
      )
      setOnClickPendingIntent(
        R.id.widget_next,
        playbackPendingIntent(context, ACTION_NEXT, widgetId),
      )
    }

    setCachedArtwork(context, views, artwork)
    appWidgetManager.updateAppWidget(widgetId, views)
    requestArtwork(context, appWidgetManager, artwork)
  }

  private fun setCachedArtwork(context: Context, views: RemoteViews, artwork: String) {
    val cached = artworkCache(context)
    val cachedArtwork = cached.getString(CACHE_ARTWORK_URI, null)
    val cachedFile = File(context.cacheDir, ARTWORK_CACHE_FILE)
    if (artwork.isNotBlank() && artwork == cachedArtwork && cachedFile.exists()) {
      BitmapFactory.decodeFile(cachedFile.path)?.let {
        views.setImageViewBitmap(R.id.widget_artwork, it)
        return
      }
    }
    views.setImageViewResource(R.id.widget_artwork, R.drawable.ic_widget_music)
  }

  private fun requestArtwork(
    context: Context,
    appWidgetManager: AppWidgetManager,
    artwork: String,
  ) {
    if (artwork.isBlank()) return
    val cached = artworkCache(context)
    val cachedFile = File(context.cacheDir, ARTWORK_CACHE_FILE)
    if (artwork == cached.getString(CACHE_ARTWORK_URI, null) && cachedFile.exists()) return

    synchronized(artworkRequests) {
      if (!artworkRequests.add(artwork)) return
    }

    artworkExecutor.execute {
      try {
        val bitmap = loadArtwork(context, artwork) ?: return@execute
        val rounded = roundedSquare(bitmap, ARTWORK_SIZE, ARTWORK_RADIUS)
        if (HomeWidgetPlugin.getData(context).getString(KEY_ARTWORK, null) != artwork) {
          return@execute
        }
        FileOutputStream(cachedFile).use {
          rounded.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        cached.edit().putString(CACHE_ARTWORK_URI, artwork).apply()

        val component = ComponentName(context, PlayerWidgetProvider::class.java)
        val ids = appWidgetManager.getAppWidgetIds(component)
        ids.forEach { widgetId ->
          val views = RemoteViews(context.packageName, R.layout.musify_player_widget)
          views.setImageViewBitmap(R.id.widget_artwork, rounded)
          appWidgetManager.partiallyUpdateAppWidget(widgetId, views)
        }
      } catch (_: Exception) {
        // Keep the placeholder when remote or local artwork is unavailable.
      } finally {
        synchronized(artworkRequests) { artworkRequests.remove(artwork) }
      }
    }
  }

  private fun loadArtwork(context: Context, artwork: String): Bitmap? {
    val uri = Uri.parse(artwork)
    return when (uri.scheme?.lowercase()) {
      "http", "https" -> {
        val connection = URL(artwork).openConnection() as HttpURLConnection
        try {
          connection.connectTimeout = 5000
          connection.readTimeout = 5000
          connection.instanceFollowRedirects = true
          connection.setRequestProperty("User-Agent", "Musify Android Widget")
          connection.inputStream.use(BitmapFactory::decodeStream)
        } finally {
          connection.disconnect()
        }
      }
      "content" -> context.contentResolver.openInputStream(uri)?.use(BitmapFactory::decodeStream)
      "file" -> BitmapFactory.decodeFile(uri.path)
      else -> BitmapFactory.decodeFile(artwork)
    }
  }

  private fun roundedSquare(source: Bitmap, size: Int, radius: Float): Bitmap {
    val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(output)
    val shader = BitmapShader(source, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
    val scale = maxOf(size.toFloat() / source.width, size.toFloat() / source.height)
    val matrix = Matrix().apply {
      setScale(scale, scale)
      postTranslate(
        (size - source.width * scale) / 2f,
        (size - source.height * scale) / 2f,
      )
    }
    shader.setLocalMatrix(matrix)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader }
    canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), radius, radius, paint)
    return output
  }

  private fun playbackPendingIntent(
    context: Context,
    action: String,
    widgetId: Int,
  ): PendingIntent {
    val intent = Intent(context, PlayerWidgetProvider::class.java).setAction(action)
    val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    return PendingIntent.getBroadcast(context, action.hashCode() + widgetId, intent, flags)
  }

  private fun controlPlayback(
    context: Context,
    action: String,
    pendingResult: BroadcastReceiver.PendingResult,
  ) {
    val mainHandler = Handler(Looper.getMainLooper())
    var browser: MediaBrowserCompat? = null
    var completed = false

    fun finish() {
      if (completed) return
      completed = true
      browser?.disconnect()
      pendingResult.finish()
    }

    val callback = object : MediaBrowserCompat.ConnectionCallback() {
      override fun onConnected() {
        try {
          val connectedBrowser = browser ?: return
          val controller = MediaControllerCompat(context, connectedBrowser.sessionToken)
          val playbackState = controller.playbackState
          if (playbackState == null || playbackState.state == PlaybackStateCompat.STATE_NONE) {
            launchAction(context, action)
            return
          }

          when (action) {
            ACTION_PLAY_PAUSE -> {
              if (
                playbackState.state == PlaybackStateCompat.STATE_PLAYING ||
                playbackState.state == PlaybackStateCompat.STATE_BUFFERING
              ) {
                controller.transportControls.pause()
                HomeWidgetPlugin.getData(context).edit().putBoolean(KEY_IS_PLAYING, false).apply()
              } else {
                controller.transportControls.play()
                HomeWidgetPlugin.getData(context).edit().putBoolean(KEY_IS_PLAYING, true).apply()
              }
            }
            ACTION_PREVIOUS -> controller.transportControls.skipToPrevious()
            ACTION_NEXT -> controller.transportControls.skipToNext()
          }
          refreshAllWidgets(context)
        } finally {
          finish()
        }
      }

      override fun onConnectionFailed() {
        launchAction(context, action)
        finish()
      }

      override fun onConnectionSuspended() = finish()
    }

    browser = MediaBrowserCompat(
      context,
      ComponentName(context, AudioService::class.java),
      callback,
      null,
    ).also { it.connect() }
    mainHandler.postDelayed(
      {
        if (!completed) launchAction(context, action)
        finish()
      },
      CONNECTION_TIMEOUT_MS,
    )
  }

  private fun launchAction(context: Context, action: String) {
    val uriAction = when (action) {
      ACTION_PREVIOUS -> "previous"
      ACTION_NEXT -> "next"
      else -> "play"
    }
    try {
      HomeWidgetLaunchIntent.getActivity(
        context,
        com.ryanheise.audioservice.AudioServiceActivity::class.java,
        Uri.parse("musify-widget://$uriAction"),
      ).send()
    } catch (_: PendingIntent.CanceledException) {
      // The next periodic widget update recreates stale pending intents.
    }
  }

  private fun refreshAllWidgets(context: Context) {
    val manager = AppWidgetManager.getInstance(context)
    val component = ComponentName(context, PlayerWidgetProvider::class.java)
    val ids = manager.getAppWidgetIds(component)
    if (ids.isNotEmpty()) {
      onUpdate(context, manager, ids, HomeWidgetPlugin.getData(context))
    }
  }

  private fun artworkCache(context: Context): SharedPreferences =
    context.getSharedPreferences(ARTWORK_CACHE_PREFERENCES, Context.MODE_PRIVATE)

  companion object {
    private const val ACTION_PLAY_PAUSE = "com.gokadzev.musify.widget.PLAY_PAUSE"
    private const val ACTION_PREVIOUS = "com.gokadzev.musify.widget.PREVIOUS"
    private const val ACTION_NEXT = "com.gokadzev.musify.widget.NEXT"
    private val playerActions = setOf(ACTION_PLAY_PAUSE, ACTION_PREVIOUS, ACTION_NEXT)

    private const val KEY_TITLE = "player_widget_title"
    private const val KEY_ARTIST = "player_widget_artist"
    private const val KEY_ARTWORK = "player_widget_artwork"
    private const val KEY_IS_PLAYING = "player_widget_is_playing"
    private const val KEY_HAS_MEDIA = "player_widget_has_media"
    private const val KEY_CAN_SKIP_PREVIOUS = "player_widget_can_skip_previous"
    private const val KEY_CAN_SKIP_NEXT = "player_widget_can_skip_next"

    private const val ARTWORK_CACHE_PREFERENCES = "musify_player_widget_cache"
    private const val CACHE_ARTWORK_URI = "artwork_uri"
    private const val ARTWORK_CACHE_FILE = "musify_player_widget_artwork.png"
    private const val ARTWORK_SIZE = 256
    private const val ARTWORK_RADIUS = 48f
    private const val CONNECTION_TIMEOUT_MS = 5000L

    private val artworkExecutor = Executors.newSingleThreadExecutor()
    private val artworkRequests = mutableSetOf<String>()
  }
}
