package au.com.sharpblue.nightmail

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "au.com.sharpblue.nightmail/badge"
    private val notificationId = 1001
    private val notificationChannelId = "nightmail_badge"

    // Content shared to NightMail through the share sheet, held until Dart takes
    // it — see lib/infrastructure/share/share_intent_service.dart. The intent is
    // kept rather than its files, so the copy runs off the main thread when Dart
    // asks, and only for a share that is actually opened.
    private val shareChannelName = "au.com.sharpblue.nightmail/share_intent"
    private var shareChannel: MethodChannel? = null
    private var pendingShare: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity (rotation) or a relaunch from Recents carries the
        // original share intent again; it was already opened the first time.
        val fromHistory = intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory && isShare(intent)) {
            pendingShare = intent
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (isShare(intent)) {
            pendingShare = intent
            shareChannel?.invokeMethod("shareReceived", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannelName)
        shareChannel?.setMethodCallHandler { call, result ->
            if (call.method != "takePendingShare") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val share = pendingShare
            pendingShare = null
            if (share == null) {
                result.success(null)
                return@setMethodCallHandler
            }
            Thread {
                val payload = try {
                    readShare(share)
                } catch (e: Exception) {
                    android.util.Log.w("NightMail", "Reading a share failed", e)
                    null
                }
                runOnUiThread { result.success(payload) }
            }.start()
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "setBadgeCount") {
                    val count = call.arguments as? Int ?: 0
                    updateBadge(count)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun updateBadge(count: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (count <= 0) {
            nm.cancel(notificationId)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                notificationChannelId,
                "Unread mail",
                NotificationManager.IMPORTANCE_MIN
            ).apply { setShowBadge(true) }
            nm.createNotificationChannel(channel)
        }
        val label = if (count == 1) "1 unread email" else "$count unread emails"
        val notification = NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(label)
            .setNumber(count)
            .setSilent(true)
            .setOngoing(true)
            .setAutoCancel(false)
            .build()
        nm.notify(notificationId, notification)
    }

    private fun isShare(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE

    /** The share as the map Dart's `SharedContent.fromMap` reads. */
    private fun readShare(intent: Intent): Map<String, Any?> {
        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            streamListExtra(intent)?.let { uris.addAll(it) }
        } else {
            streamExtra(intent)?.let { uris.add(it) }
        }
        // Dart deletes each copy once it has read it; clearing here as well
        // catches the copies of a share that never got as far as compose.
        val root = File(cacheDir, "shared").apply { deleteRecursively() }
        val dir = File(root, System.currentTimeMillis().toString()).apply { mkdirs() }
        val files = uris.mapIndexedNotNull { i, uri -> copySharedUri(uri, dir, i, intent.type) }
        return mapOf(
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT),
            "text" to intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
            "files" to files,
        )
    }

    /**
     * Copies one shared stream into the app's cache. Only `content:` URIs are
     * accepted: a `file:` URI from another app could name one of NightMail's own
     * private files, which would then go out as an attachment.
     */
    private fun copySharedUri(uri: Uri, dir: File, index: Int, intentType: String?): Map<String, Any?>? {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) return null
        val name = displayName(uri)
            ?.replace('/', '_')
            ?.takeIf { it.isNotBlank() && it != "." && it != ".." }
            ?: "attachment-${index + 1}"
        // Two shared files can carry the same display name.
        val dest = File(File(dir, index.toString()).apply { mkdirs() }, name)
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { src -> dest.outputStream().use { src.copyTo(it) } }
        val mime = contentResolver.getType(uri)
            ?: intentType?.takeUnless { it.contains('*') }
        return mapOf("path" to dest.absolutePath, "name" to name, "mimeType" to mime)
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (e: Exception) {
        null
    } ?: uri.lastPathSegment

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }
}
