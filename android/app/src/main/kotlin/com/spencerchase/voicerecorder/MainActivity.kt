package com.spencerchase.voicerecorder

import android.content.Context
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
    }
}
