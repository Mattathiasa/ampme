package com.ampme.ampme

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground service that captures the device's **system audio** — whatever
 * other apps are playing (music, games, video) — via MediaProjection +
 * AudioPlaybackCapture, and streams the raw 16-bit PCM to Dart through
 * [MainActivity.pcmEventSink].
 *
 * Running as a foreground service with type `mediaProjection` is what lets
 * the capture continue while the user switches to the app they actually want
 * to play music from (the whole point of the feature). The user must approve
 * the system "start recording" consent dialog first, and can stop the
 * broadcast from the notification, which triggers [MediaProjection.Callback.onStop].
 *
 * Only ever started on Android 10+ (the Dart layer gates on `isSupported`),
 * which is also the floor for `AudioPlaybackCaptureConfiguration`.
 */
class SystemAudioCaptureService : Service() {
    companion object {
        private const val TAG = "AmpmeSystemAudio"
        private const val CHANNEL_ID = "ampme_system_audio_capture"
        private const val NOTIFICATION_ID = 2
        private const val SAMPLE_RATE = 44100

        /// True while this service is actively capturing, so the activity can
        /// short-circuit duplicate `start` requests.
        @Volatile
        var isRunning = false
    }

    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    private var stopRequested = false

    private val projectionCallback =
        object : MediaProjection.Callback() {
            override fun onStop() {
                // The user tapped the system "Stop" control on the projection
                // notification (or consent was revoked): tear everything down.
                Log.i(TAG, "Projection stopped by system/user")
                stopSelf()
            }
        }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val resultCode = intent?.getIntExtra(MainActivity.EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
            ?: Activity.RESULT_CANCELED
        val resultData = intent.parcelableExtra(MainActivity.EXTRA_RESULT_DATA)
        if (resultCode != Activity.RESULT_OK || resultData == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        startAsForeground()
        startCapture(resultCode, resultData)
        return START_NOT_STICKY
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startCapture(resultCode: Int, resultData: Intent) {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        // Android 14+ requires a callback to be registered on the projection
        // before it is used; register synchronously, right after creation.
        // The SDK stubs mark getMediaProjection as nullable, but a validated
        // consent result always yields a projection — guard anyway.
        val projection = manager.getMediaProjection(resultCode, resultData)
            ?: run {
                Log.e(TAG, "getMediaProjection returned null for a granted consent")
                stopSelf()
                return
            }
        mediaProjection = projection
        projection.registerCallback(projectionCallback, Handler(Looper.getMainLooper()))

        // Any failure below (a device reporting a bad buffer size, an
        // AudioRecord that fails to initialize, etc.) must NOT crash the
        // service — the activity has already returned the `start` result, so
        // a crash would leave the Dart side stuck "broadcasting" forever.
        // Degrade into stopSelf() instead, which flows through onDestroy →
        // endOfStream → the Dart side tears itself down gracefully.
        try {
            setupCapture(projection)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start system audio capture", e)
            stopSelf()
        }
    }

    private fun setupCapture(projection: MediaProjection) {
        val captureConfig =
            AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()

        val format =
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build()

        // getMinBufferSize returns a negative error code on unsupported
        // configs; fall back to a sane default so we never pass a negative
        // size into the builder (which would throw).
        val minBufferSize =
            AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
        val bufferSize = if (minBufferSize > 0) minBufferSize * 2 else 20 * 1024
        val record =
            AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize)
                .setAudioPlaybackCaptureConfig(captureConfig)
                .build()
        check(record.state == AudioRecord.STATE_INITIALIZED) {
            "AudioRecord failed to initialize"
        }
        audioRecord = record

        isRunning = true
        record.startRecording()
        val chunkSize = if (minBufferSize > 0) maxOf(minBufferSize, 4096) else 8192
        captureThread = Thread({ readLoop(record, chunkSize) }, "ampme-system-audio").also { it.start() }
    }

    /// Reads captured PCM in a loop and forwards each chunk to the Flutter
    /// side. Runs on a dedicated thread so recording never stalls the UI.
    private fun readLoop(record: AudioRecord, chunkSize: Int) {
        val buffer = ByteArray(chunkSize)
        while (!stopRequested) {
            val read = record.read(buffer, 0, buffer.size)
            if (read > 0) {
                MainActivity.pcmEventSink?.success(buffer.copyOf(read))
            } else if (read < 0) {
                // ERROR_INVALID_OPERATION etc. — the projection likely ended.
                Log.w(TAG, "AudioRecord read error: $read")
                stopSelf()
                return
            }
        }
    }

    private fun buildNotification(): Notification {
        val contentIntent =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE,
            )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Broadcasting device audio")
            .setContentText("Ampme is streaming audio from your device to the session.")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel =
                NotificationChannel(
                    CHANNEL_ID,
                    "Device audio broadcast",
                    NotificationManager.IMPORTANCE_LOW,
                )
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        stopRequested = true
        captureThread = null

        audioRecord?.let {
            runCatching { it.stop() }
            it.release()
        }
        audioRecord = null

        mediaProjection?.let {
            runCatching { it.stop() }
        }
        mediaProjection = null

        isRunning = false
        // Tell Dart the capture ended so it can tear down its broadcast state.
        MainActivity.pcmEventSink?.endOfStream()
        MainActivity.pcmEventSink = null
        super.onDestroy()
    }

    /** Typed (and deprecation-safe) parcelable extra read. */
    @Suppress("DEPRECATION")
    private fun Intent?.parcelableExtra(name: String): Intent? =
        when {
            this == null -> null
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                getParcelableExtra(name, Intent::class.java)
            else -> getParcelableExtra(name)
        }
}
