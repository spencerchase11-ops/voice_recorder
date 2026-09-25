package com.spencerchase.voicerecorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent

/**
 * Foreground service of type "mediaPlayback" that keeps a recording playing
 * with the app in the background, and shows the controls: a media
 * notification (back 10 s, play/pause, forward 10 s, seek bar), the same on
 * the lock screen, and headset and Bluetooth buttons, all through a
 * [MediaSession].
 *
 * The Flutter side plays the audio and sends the player's state
 * ([update]); the buttons go back to it as "mediaAction" calls. It runs while
 * something plays and for [IDLE_TIMEOUT_MS] after a pause, so the recording
 * can be resumed from the lock screen, then goes away.
 */
class PlaybackService : Service() {

    /** What the controls show. */
    data class Info(
        val title: String,
        val durationMs: Long,
        val positionMs: Long,
        val playing: Boolean,
        val speed: Float,
    )

    private lateinit var session: MediaSession
    private val handler = Handler(Looper.getMainLooper())
    private var inForeground = false
    private var shown: Info? = null
    private var art: Bitmap? = null

    // Paused for a while: the controls go away.
    private val idleTimeout = Runnable {
        NativePlugin.emit("mediaAction", mapOf("action" to "dismiss"))
        shutDown()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        session = MediaSession(this, "VoiceRecorder").apply {
            setCallback(callback, handler)
            setSessionActivity(openApp())
            isActive = true
        }
        art = appIcon()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> send(if (shown?.playing == true) "pause" else "play")
            ACTION_REWIND -> send("rewind")
            ACTION_FORWARD -> send("forward")
            ACTION_DISMISS -> {
                send("dismiss")
                shutDown()
                return START_NOT_STICKY
            }
        }
        // Started with startForegroundService(): the foreground must follow,
        // even if the controls were cleared meanwhile.
        val info = pending
        if (!inForeground) {
            if (!goForeground(info)) return START_NOT_STICKY
            if (info == null) {
                shutDown()
                return START_NOT_STICKY
            }
        }
        if (info != null) apply(info)
        return START_NOT_STICKY
    }

    private fun goForeground(info: Info?): Boolean {
        val notification = buildNotification(info ?: Info("", 0, 0, false, 1f))
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            inForeground = true
            true
        } catch (e: RuntimeException) {
            // Refused (e.g. started from the background): no controls then,
            // but no crash either.
            Log.w(TAG, "Could not start the playback service in the foreground", e)
            stopSelf()
            false
        }
    }

    /** Shows [info] in the session and the notification. */
    private fun apply(info: Info) {
        val previous = shown
        shown = info
        if (previous == null || previous.title != info.title || previous.durationMs != info.durationMs) {
            val meta = MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, info.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, getString(R.string.app_name))
                .putLong(MediaMetadata.METADATA_KEY_DURATION, info.durationMs)
            art?.let { meta.putBitmap(MediaMetadata.METADATA_KEY_ART, it) }
            session.setMetadata(meta.build())
        }
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO or
                        PlaybackState.ACTION_STOP or PlaybackState.ACTION_FAST_FORWARD or
                        PlaybackState.ACTION_REWIND,
                )
                .setState(
                    if (info.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    info.positionMs,
                    if (info.playing) info.speed else 0f,
                    SystemClock.elapsedRealtime(),
                )
                // Android 13+ builds the controls from these: they take the
                // places next to play/pause.
                .addCustomAction(
                    PlaybackState.CustomAction.Builder(CUSTOM_REWIND, getString(R.string.back_10), R.drawable.ic_media_rewind10)
                        .build(),
                )
                .addCustomAction(
                    PlaybackState.CustomAction.Builder(CUSTOM_FORWARD, getString(R.string.forward_10), R.drawable.ic_media_forward10)
                        .build(),
                )
                .build(),
        )
        if (inForeground) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(info))
        }
        handler.removeCallbacks(idleTimeout)
        if (!info.playing) handler.postDelayed(idleTimeout, IDLE_TIMEOUT_MS)
    }

    private fun shutDown() {
        handler.removeCallbacks(idleTimeout)
        if (instance === this) instance = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        inForeground = false
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away from Recents while paused: nothing to keep around.
        if (shown?.playing != true) {
            send("dismiss")
            shutDown()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacks(idleTimeout)
        if (instance === this) instance = null
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    private fun send(action: String, position: Long? = null) {
        val args = HashMap<String, Any?>()
        args["action"] = action
        if (position != null) args["position"] = position
        // Without the Flutter engine nobody can play; take the controls away.
        if (!NativePlugin.emit("mediaAction", args)) shutDown()
    }

    private val callback = object : MediaSession.Callback() {
        override fun onPlay() = send("play")
        override fun onPause() = send("pause")
        override fun onStop() = send("stop")
        override fun onSeekTo(pos: Long) = send("seek", pos)
        override fun onFastForward() = send("forward")
        override fun onRewind() = send("rewind")
        override fun onSkipToNext() = send("forward")
        override fun onSkipToPrevious() = send("rewind")

        override fun onCustomAction(action: String, extras: Bundle?) {
            when (action) {
                CUSTOM_REWIND -> send("rewind")
                CUSTOM_FORWARD -> send("forward")
            }
        }

        override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
            // Headset "next" and "previous" skip 10 seconds (there is no
            // other recording to go to).
            val event = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
            } else {
                @Suppress("DEPRECATION")
                mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
            }
            if (event != null && event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                when (event.keyCode) {
                    KeyEvent.KEYCODE_MEDIA_NEXT -> {
                        send("forward")
                        return true
                    }
                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                        send("rewind")
                        return true
                    }
                }
            }
            return super.onMediaButtonEvent(mediaButtonIntent)
        }
    }

    private fun openApp(): PendingIntent {
        // The same intent as the launcher icon: brings the app back as it was.
        val launch = Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun serviceIntent(action: String, requestCode: Int): PendingIntent = PendingIntent.getService(
        this,
        requestCode,
        Intent(this, PlaybackService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun action(action: String, icon: Int, label: Int, requestCode: Int): Notification.Action =
        Notification.Action.Builder(Icon.createWithResource(this, icon), getString(label), serviceIntent(action, requestCode))
            .build()

    private fun buildNotification(info: Info): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, getString(R.string.playback_channel), NotificationManager.IMPORTANCE_LOW).apply {
                        setShowBadge(false)
                    },
                )
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_playback)
            .setContentTitle(info.title)
            .setContentText(getString(R.string.app_name))
            .setContentIntent(openApp())
            .setDeleteIntent(serviceIntent(ACTION_DISMISS, 13))
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setOngoing(info.playing)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .addAction(action(ACTION_REWIND, R.drawable.ic_media_rewind10, R.string.back_10, 10))
            .addAction(
                if (info.playing) {
                    action(ACTION_TOGGLE, R.drawable.ic_media_pause, R.string.pause, 11)
                } else {
                    action(ACTION_TOGGLE, R.drawable.ic_media_play, R.string.play, 11)
                },
            )
            .addAction(action(ACTION_FORWARD, R.drawable.ic_media_forward10, R.string.forward_10, 12))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
        art?.let { builder.setLargeIcon(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    /** The app icon as a bitmap, for the notification and the lock screen. */
    private fun appIcon(): Bitmap? = try {
        val d = getDrawable(R.mipmap.ic_launcher)
        if (d == null) {
            null
        } else {
            val size = 192
            Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
                d.setBounds(0, 0, size, size)
                d.draw(Canvas(it))
            }
        }
    } catch (e: RuntimeException) {
        null
    }

    companion object {
        private const val TAG = "PlaybackService"
        private const val CHANNEL_ID = "playback"
        private const val NOTIFICATION_ID = 2
        private const val IDLE_TIMEOUT_MS = 10 * 60 * 1000L
        private const val ACTION_TOGGLE = "com.spencerchase.voicerecorder.playback.TOGGLE"
        private const val ACTION_REWIND = "com.spencerchase.voicerecorder.playback.REWIND"
        private const val ACTION_FORWARD = "com.spencerchase.voicerecorder.playback.FORWARD"
        private const val ACTION_DISMISS = "com.spencerchase.voicerecorder.playback.DISMISS"
        private const val CUSTOM_REWIND = "rewind10"
        private const val CUSTOM_FORWARD = "forward10"

        private var instance: PlaybackService? = null

        /** The latest state from the Flutter side; null once cleared. */
        private var pending: Info? = null

        /** Shows (or updates) the controls; starts the service once playing. */
        fun update(context: Context, info: Info) {
            pending = info
            val running = instance
            if (running != null) {
                running.apply(info)
            } else if (info.playing) {
                val intent = Intent(context, PlaybackService::class.java)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                } catch (e: RuntimeException) {
                    // Not allowed right now (the app is in the background):
                    // playback goes on without the controls.
                    Log.w(TAG, "Could not start the playback service", e)
                }
            }
        }

        /** Removes the controls. */
        fun clear() {
            pending = null
            // A service that isn't in the foreground yet must get there before
            // it may stop (Android crashes the app otherwise); onStartCommand
            // then sees nothing pending and stops it.
            instance?.takeIf { it.inForeground }?.shutDown()
        }
    }
}
