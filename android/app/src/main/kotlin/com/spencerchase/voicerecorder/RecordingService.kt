package com.spencerchase.voicerecorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Foreground service of type "microphone" that runs while a recording is in
 * progress. Android only lets an app keep capturing audio in the background
 * while such a service is running; it also holds a partial wake lock so long
 * recordings survive the screen turning off.
 *
 * Its notification shows the recording time and has Pause/Resume and Stop
 * buttons, which the Flutter side acts on. While it runs, other apps' music
 * is paused (like the phone's own recorder does) and resumes afterwards.
 *
 * The audio itself is captured and encoded by the Flutter side.
 */
class RecordingService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var inForeground = false

    // A recording carries on whatever other apps do with the audio focus.
    private val focusListener = AudioManager.OnAudioFocusChangeListener { }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> NativePlugin.emit("recordingAction", mapOf("action" to "pause"))
            ACTION_RESUME -> NativePlugin.emit("recordingAction", mapOf("action" to "resume"))
            ACTION_STOP -> NativePlugin.emit("recordingAction", mapOf("action" to "stop"))
            else -> {
                text = intent?.getStringExtra(EXTRA_TEXT) ?: getString(R.string.recording)
                title = intent?.getStringExtra(EXTRA_TITLE) ?: getString(R.string.app_name)
                paused = false
                startedAt = System.currentTimeMillis()
                if (!goForeground()) return START_NOT_STICKY
                holdWakeLock()
                requestAudioFocus()
            }
        }
        return START_NOT_STICKY
    }

    private fun goForeground(): Boolean {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            inForeground = true
            return true
        } catch (e: RuntimeException) {
            // Android refused the foreground service (e.g. started from the
            // background). The recording still runs while the app is visible;
            // don't crash the app over it.
            Log.w(TAG, "Could not start the recording service in the foreground", e)
            stopSelf()
            return false
        }
    }

    private fun holdWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "VoiceRecorder:recording").apply {
            setReferenceCounted(false)
            // Safety net: never hold the CPU awake for more than 24 hours.
            acquire(24 * 60 * 60 * 1000L)
        }
    }

    /** Pauses other apps' music for the length of the recording. */
    private fun requestAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (focusRequest != null) return
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build(),
                    )
                    .setOnAudioFocusChangeListener(focusListener)
                    .build()
                focusRequest = request
                am.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not request audio focus", e)
        }
    }

    private fun abandonAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusListener)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not abandon audio focus", e)
        }
    }

    /** Shows the new state of the recording in the notification. */
    private fun show(newText: String, newPaused: Boolean, elapsedMs: Long) {
        text = newText
        paused = newPaused
        // The notification's timer counts from here, so it shows the time
        // recorded (pauses excluded).
        startedAt = System.currentTimeMillis() - elapsedMs
        if (!inForeground) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        abandonAudioFocus()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        inForeground = false
        super.onDestroy()
    }

    private var title = ""
    private var text = ""
    private var paused = false
    private var startedAt = 0L

    private fun action(action: String, icon: Int, label: Int, requestCode: Int): Notification.Action {
        val intent = PendingIntent.getService(
            this,
            requestCode,
            Intent(this, RecordingService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), getString(label), intent).build()
    }

    private fun buildNotification(): Notification {
        // The same intent as the launcher icon, so tapping the notification
        // brings the existing task to the front instead of stacking a second
        // MainActivity on top of whatever is showing.
        val launch = Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        val openApp = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, getString(R.string.recording_channel), NotificationManager.IMPORTANCE_LOW).apply {
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
            .setSmallIcon(R.drawable.ic_stat_mic)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                if (paused) {
                    action(ACTION_RESUME, R.drawable.ic_media_record, R.string.resume, 1)
                } else {
                    action(ACTION_PAUSE, R.drawable.ic_media_pause, R.string.pause, 2)
                },
            )
            .addAction(action(ACTION_STOP, R.drawable.ic_media_stop, R.string.stop, 3))
        if (paused) {
            builder.setShowWhen(false).setUsesChronometer(false)
        } else {
            builder.setShowWhen(true).setUsesChronometer(true).setWhen(startedAt)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "RecordingService"
        private const val CHANNEL_ID = "recording"
        private const val NOTIFICATION_ID = 1
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val ACTION_PAUSE = "com.spencerchase.voicerecorder.recording.PAUSE"
        private const val ACTION_RESUME = "com.spencerchase.voicerecorder.recording.RESUME"
        private const val ACTION_STOP = "com.spencerchase.voicerecorder.recording.STOP"

        private var instance: RecordingService? = null

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, RecordingService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Shows whether the recording is paused, and how long it has run. */
        fun update(text: String, paused: Boolean, elapsedMs: Long) {
            instance?.show(text, paused, elapsedMs)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingService::class.java))
        }
    }
}
