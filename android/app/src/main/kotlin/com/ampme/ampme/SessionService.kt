package com.ampme.ampme

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Keeps a session alive with the screen off: a `mediaPlayback` foreground
 * service holding a partial wakelock (the CPU keeps running, so Dart timers -
 * the 1 s sync loop, clock sync - keep firing) and a Wi-Fi lock (the radio
 * doesn't nap, so sync messages and live audio keep arriving on time).
 *
 * Started by Dart when a session begins (host or listener) and stopped when
 * it ends. A listener's notification has a Leave action.
 */
class SessionService : Service() {
    companion object {
        const val ACTION_LEAVE = "com.ampme.ampme.SESSION_LEAVE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_CAN_LEAVE = "can_leave"
        private const val CHANNEL_ID = "ampme_session"
        private const val NOTIFICATION_ID = 3

        /// Set by [MainActivity]: tells Dart the user tapped Leave.
        @Volatile
        var onLeave: (() -> Unit)? = null

        @Volatile
        var isRunning = false
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel =
                NotificationChannel(CHANNEL_ID, "Session", NotificationManager.IMPORTANCE_LOW)
            channel.description = "Shown while this device is in an Ampme session"
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_LEAVE) {
            onLeave?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        val notification =
            buildNotification(
                intent?.getStringExtra(EXTRA_TITLE) ?: "Ampme",
                intent?.getStringExtra(EXTRA_TEXT) ?: "In a session",
                intent?.getBooleanExtra(EXTRA_CAN_LEAVE, false) ?: false,
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        isRunning = true
        return START_NOT_STICKY
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock =
                power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ampme:session").apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
            wifiLock =
                wifi.createWifiLock(mode, "ampme:session").apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    override fun onDestroy() {
        isRunning = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        super.onDestroy()
    }

    private fun buildNotification(title: String, text: String, canLeave: Boolean): Notification {
        val open =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentIntent(open)
                .setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
        if (canLeave) {
            val leave =
                PendingIntent.getService(
                    this,
                    1,
                    Intent(this, SessionService::class.java).setAction(ACTION_LEAVE),
                    PendingIntent.FLAG_IMMUTABLE,
                )
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Leave", leave)
        }
        return builder.build()
    }
}
