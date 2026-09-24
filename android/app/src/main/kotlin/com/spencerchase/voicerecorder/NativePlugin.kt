package com.spencerchase.voicerecorder

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.Settings
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Platform side of lib/src/platform/native_bridge.dart.
 *
 * Recordings live in a folder the user grants through the Storage Access
 * Framework (the original app wrote to /storage/emulated/0/Recorders, which
 * modern Android only exposes this way). Every file operation runs on a
 * background thread and answers on the main thread.
 */
class NativePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {

    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var pendingPick: MethodChannel.Result? = null
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val activity: Activity? get() = binding?.activity

    // ---------------------------------------------------------- lifecycle
    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        io.shutdown()
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b
        b.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    // ------------------------------------------------------------ calls
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(call.argument("initialPath"), result)
            "hasFolderAccess" -> background(result) { hasFolderAccess(Uri.parse(call.argument<String>("treeUri"))) }
            "folderPath" -> background(result) { folderPath(Uri.parse(call.argument<String>("treeUri"))) }
            "listFolder" -> background(result) { listFolder(Uri.parse(call.argument<String>("treeUri"))) }
            "statDocument" -> background(result) { stat(Uri.parse(call.argument<String>("documentUri"))) }
            "importFile" -> background(result) {
                importFile(
                    Uri.parse(call.argument<String>("treeUri")),
                    call.argument<String>("sourcePath")!!,
                    call.argument<String>("displayName")!!,
                    call.argument<String>("mimeType")!!,
                )
            }
            "renameDocument" -> background(result) {
                val uri = Uri.parse(call.argument<String>("documentUri"))
                val renamed = DocumentsContract.renameDocument(
                    context.contentResolver, uri, call.argument<String>("displayName")!!,
                ) ?: throw IllegalStateException("The folder refused to rename the file")
                stat(renamed)
            }
            "deleteDocument" -> background(result) { delete(Uri.parse(call.argument<String>("documentUri"))) }
            "shareDocument" -> {
                share(Uri.parse(call.argument<String>("documentUri")), call.argument<String>("mimeType")!!)
                result.success(null)
            }
            "startRecordingService" -> {
                requestNotificationPermission()
                RecordingService.start(context, call.argument("title")!!, call.argument("text")!!)
                result.success(null)
            }
            "stopRecordingService" -> {
                RecordingService.stop(context)
                result.success(null)
            }
            "storageSpace" -> background(result) { storageSpace(call.argument("location")) }
            "openAppSettings" -> {
                try {
                    openAppSettings()
                    result.success(null)
                } catch (e: RuntimeException) {
                    // e.g. no settings activity on an unusual device
                    result.error("settings", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** This app's page in the system settings, where the microphone can be allowed. */
    private fun openAppSettings() {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        )
        val act = activity
        if (act != null) {
            act.startActivity(intent)
        } else {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun <T> background(result: MethodChannel.Result, work: () -> T) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("native_error", e.message ?: e.toString(), null) }
            }
        }
    }

    // ------------------------------------------------------- folder picker
    private fun pickFolder(initialPath: String?, result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("no_activity", "The folder picker needs a visible activity", null)
            return
        }
        if (pendingPick != null) {
            result.error("busy", "The folder picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            initialUriFor(initialPath)?.let { intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
        }
        try {
            act.startActivityForResult(intent, REQUEST_PICK_FOLDER)
            pendingPick = result
        } catch (e: ActivityNotFoundException) {
            result.error("no_picker", "This device has no folder picker", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_FOLDER) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        val rw = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        if ((data?.flags ?: 0) and rw != rw) {
            result.error("read_only", "Recordings can't be saved in that folder", null)
            return true
        }
        try {
            context.contentResolver.takePersistableUriPermission(tree, rw)
            // Keep only the folder the user just chose.
            for (p in context.contentResolver.persistedUriPermissions) {
                if (p.uri != tree) {
                    context.contentResolver.releasePersistableUriPermission(
                        p.uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
            }
            result.success(tree.toString())
        } catch (e: SecurityException) {
            result.error("no_permission", e.message, null)
        }
        return true
    }

    /** `/storage/emulated/0/Recorders` -> a document URI the picker can open at. */
    private fun initialUriFor(path: String?): Uri? {
        if (path == null) return null
        val primary = Environment.getExternalStorageDirectory().path
        val emulated = Regex("^/storage/emulated/\\d+(/(.*))?$").find(path)
        val docId = when {
            path == primary -> "primary:"
            path.startsWith("$primary/") -> "primary:" + path.removePrefix("$primary/")
            emulated != null -> "primary:" + (emulated.groupValues[2])
            path.startsWith("/storage/") -> {
                val rest = path.removePrefix("/storage/")
                val volume = rest.substringBefore('/')
                "$volume:" + rest.substringAfter('/', "")
            }
            else -> return null
        }
        return DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_AUTHORITY, docId)
    }

    // ---------------------------------------------------------- queries
    private fun hasFolderAccess(tree: Uri): Boolean {
        val granted = context.contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }
        if (!granted) return false
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return try {
            context.contentResolver.query(root, arrayOf(Document.COLUMN_DOCUMENT_ID), null, null, null)
                ?.use { it.moveToFirst() } ?: false
        } catch (e: Exception) {
            false
        }
    }

    private fun folderPath(tree: Uri): String {
        val docId = DocumentsContract.getTreeDocumentId(tree)
        if (tree.authority == EXTERNAL_STORAGE_AUTHORITY) {
            val volume = docId.substringBefore(':')
            val rel = docId.substringAfter(':', "")
            val base = if (volume == "primary") Environment.getExternalStorageDirectory().path else "/storage/$volume"
            return if (rel.isEmpty()) base else "$base/$rel"
        }
        // Other providers (e.g. cloud drives): show the folder's name.
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
        context.contentResolver.query(root, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0)
        }
        return docId
    }

    private val columns = arrayOf(
        Document.COLUMN_DOCUMENT_ID,
        Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_SIZE,
        Document.COLUMN_LAST_MODIFIED,
        Document.COLUMN_MIME_TYPE,
    )

    private fun row(c: Cursor, uri: Uri): Map<String, Any?> = mapOf(
        "id" to uri.toString(),
        "name" to c.getString(1),
        "size" to (if (c.isNull(2)) 0L else c.getLong(2)),
        "modified" to (if (c.isNull(3)) 0L else c.getLong(3)),
    )

    private fun listFolder(tree: Uri): List<Map<String, Any?>> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val out = ArrayList<Map<String, Any?>>()
        val cursor = context.contentResolver.query(children, columns, null, null, null)
            ?: throw IllegalStateException("The recordings folder can't be read")
        cursor.use { c ->
            while (c.moveToNext()) {
                if (c.getString(4) == Document.MIME_TYPE_DIR) continue
                if (c.getString(1)?.startsWith(".") != false) continue
                out.add(row(c, DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))))
            }
        }
        return out
    }

    /** Null when the document no longer exists; throws if storage can't be reached. */
    private fun stat(uri: Uri): Map<String, Any?>? {
        try {
            return context.contentResolver.query(uri, columns, null, null, null)?.use { c ->
                if (c.moveToFirst()) row(c, uri) else null
            }
        } catch (e: Exception) {
            // Providers throw (rather than return nothing) for a deleted file or
            // one in a folder we no longer have access to.
            if (isGone(uri)) return null
            throw e
        }
    }

    /**
     * Whether [uri] (a document inside a granted folder) is known to be gone:
     * its folder is no longer granted, or the folder is readable but the
     * document isn't. False when the folder itself can't be reached.
     */
    private fun isGone(uri: Uri): Boolean {
        val treeId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (e: IllegalArgumentException) {
            return true
        }
        val authority = uri.authority ?: return true
        val tree = DocumentsContract.buildTreeDocumentUri(authority, treeId)
        val granted = context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }
        if (!granted) return true
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, treeId)
        return try {
            context.contentResolver.query(root, arrayOf(Document.COLUMN_DOCUMENT_ID), null, null, null)
                ?.use { it.moveToFirst() } ?: false
        } catch (e: Exception) {
            false
        }
    }

    private fun delete(uri: Uri): Boolean = try {
        DocumentsContract.deleteDocument(context.contentResolver, uri)
    } catch (e: Exception) {
        // Already deleted (e.g. in a file manager) counts as deleted.
        if (isGone(uri)) true else throw e
    }

    // ------------------------------------------------------------ writes
    private fun importFile(tree: Uri, sourcePath: String, displayName: String, mimeType: String): Map<String, Any?>? {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        // Use the MIME type Android associates with the extension so the
        // provider keeps our file name unchanged.
        val ext = displayName.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: mimeType
        val target = DocumentsContract.createDocument(context.contentResolver, parent, mime, displayName)
            ?: throw IllegalStateException("Could not create $displayName")
        try {
            FileInputStream(File(sourcePath)).use { input ->
                val output = context.contentResolver.openOutputStream(target, "w")
                    ?: throw IllegalStateException("Could not open $displayName")
                output.use {
                    input.copyTo(it, 256 * 1024)
                    it.flush()
                    // The source is deleted as soon as we return: make sure the copy is on
                    // disk. Best effort; not every provider's descriptor supports it.
                    try {
                        (it as? FileOutputStream)?.fd?.sync()
                    } catch (e: IOException) {
                    }
                }
            }
        } catch (e: Exception) {
            try {
                DocumentsContract.deleteDocument(context.contentResolver, target)
            } catch (cleanup: Exception) {
                e.addSuppressed(cleanup)
            }
            throw e
        }
        return stat(target)
    }

    private fun share(uri: Uri, mimeType: String) {
        val send = Intent(Intent.ACTION_SEND)
            .setType(mimeType)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(null, uri)
        val chooser = Intent.createChooser(send, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val act = activity
        if (act != null) {
            act.startActivity(chooser)
        } else {
            context.startActivity(chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    // ------------------------------------------------------------- misc
    /**
     * Free space where recordings go. A recording is written to internal app
     * storage while it runs and copied into the folder when it stops, so this
     * reports both volumes and whether they are the same one (emulated
     * primary storage lives on the internal data partition).
     */
    private fun storageSpace(location: String?): Map<String, Any> {
        var path = Environment.getExternalStorageDirectory().path
        var primary = true
        if (location != null && location.startsWith("content://")) {
            val tree = Uri.parse(location)
            if (tree.authority == EXTERNAL_STORAGE_AUTHORITY) {
                val volume = DocumentsContract.getTreeDocumentId(tree).substringBefore(':')
                if (volume != "primary") {
                    primary = false
                    // Our own directory on that volume is always readable.
                    context.getExternalFilesDirs(null).firstOrNull { it?.path?.startsWith("/storage/$volume") == true }
                        ?.let { path = it.path }
                }
            }
        }
        return mapOf(
            "destination" to StatFs(path).availableBytes,
            "internal" to StatFs(context.filesDir.path).availableBytes,
            "sameVolume" to (primary && Environment.isExternalStorageEmulated()),
        )
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val act = activity ?: return
        if (act.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            act.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
    }

    companion object {
        const val CHANNEL = "com.spencerchase.voicerecorder/native"
        private const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"
        private const val REQUEST_PICK_FOLDER = 0x5646
        private const val REQUEST_NOTIFICATIONS = 0x5647
    }
}
