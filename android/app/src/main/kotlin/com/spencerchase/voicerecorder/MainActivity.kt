package com.spencerchase.voicerecorder

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Hosts the Flutter UI on a process-wide engine.
 *
 * The engine (and with it the Dart code that is encoding a recording) outlives
 * the activity: leaving the app with Back or swiping it away from Recents must
 * not stop a recording. [RecordingService] keeps the process in the
 * foreground while a recording runs.
 */
class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // A re-created activity still carries the intent it was first opened
        // with; only a fresh start from the shortcut means "record".
        if (savedInstanceState == null) noteLaunch(intent)
        super.onCreate(savedInstanceState)
        // Volume keys adjust playback volume here, not the ringer.
        volumeControlStream = AudioManager.STREAM_MUSIC
        publishShortcuts()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        noteLaunch(intent)
    }

    /** Remembers a "Record" shortcut for the Dart side to pick up. */
    private fun noteLaunch(intent: Intent?) {
        if (intent == null || intent.action != ACTION_RECORD) return
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        NativePlugin.launchAction = "record"
    }

    /** The launcher's long-press menu gets "Start recording". */
    private fun publishShortcuts() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        try {
            val manager = getSystemService(ShortcutManager::class.java) ?: return
            if (manager.dynamicShortcuts.any { it.id == SHORTCUT_RECORD }) return
            val shortcut = ShortcutInfo.Builder(this, SHORTCUT_RECORD)
                .setShortLabel(getString(R.string.shortcut_record_short))
                .setLongLabel(getString(R.string.shortcut_record_long))
                .setIcon(Icon.createWithResource(this, R.drawable.ic_shortcut_record))
                .setIntent(
                    Intent(this, MainActivity::class.java)
                        .setAction(ACTION_RECORD)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                )
                .build()
            manager.dynamicShortcuts = listOf(shortcut)
        } catch (e: RuntimeException) {
            // Rate limited or no launcher support: the shortcut is optional.
            Log.w("MainActivity", "Could not publish the shortcut", e)
        }
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        return FlutterEngine(context.applicationContext).also { engine ->
            engine.plugins.add(NativePlugin())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    /**
     * Another MainActivity took over the shared engine. This one can only show
     * a blank screen now, so close it instead of leaving it in the back stack.
     */
    override fun detachFromFlutterEngine() {
        super.detachFromFlutterEngine()
        finish()
    }

    companion object {
        private const val ENGINE_ID = "voice_recorder"
        private const val SHORTCUT_RECORD = "record"
        private const val ACTION_RECORD = "com.spencerchase.voicerecorder.RECORD"
    }
}
