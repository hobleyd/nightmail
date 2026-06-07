package au.com.sharpblue.nightmail

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "au.com.sharpblue.nightmail/badge"
    private val notificationId = 1001
    private val notificationChannelId = "nightmail_badge"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
