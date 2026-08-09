package com.ampme.ampme

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "com.ampme/system_audio_capture"
        const val EVENTS = "com.ampme/system_audio_capture/events"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"

        /// The live PCM sink that [SystemAudioCaptureService] streams captured
        /// audio into. Set while Dart has an active EventChannel listener.
        @Volatile
        var pcmEventSink: EventChannel.EventSink? = null
    }

    /// Request code for the MediaProjection consent dialog.
    private val captureRequestCode = 0x5A1D
    /// The MethodChannel result to complete once the user answers the consent
    /// dialog (a `start` request is pending).
    private var pendingStartResult: Result? = null
    private var projectionResultCode = 0
    private var projectionResultData: Intent? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleMethodCall)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        pcmEventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        pcmEventSink = null
                    }
                },
            )
    }

    private fun handleMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // MediaProjection playback capture needs Android 10+.
            "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            "start" -> startCapture(result)
            "stop" -> {
                stopCaptureService()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /// Launches the system consent dialog for screen/audio capture; [result]
    /// completes when the user approves (capture starts) or denies it.
    private fun startCapture(result: Result) {
        if (SystemAudioCaptureService.isRunning) {
            result.success(null)
            return
        }
        if (pendingStartResult != null) {
            result.error("BUSY", "A capture request is already in progress.", null)
            return
        }
        pendingStartResult = result
        val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(manager.createScreenCaptureIntent(), captureRequestCode)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != captureRequestCode) return

        val startResult = pendingStartResult
        pendingStartResult = null
        if (startResult == null) return

        if (resultCode == Activity.RESULT_OK && data != null) {
            projectionResultCode = resultCode
            projectionResultData = data
            startCaptureService()
            startResult.success(null)
        } else {
            startResult.error(
                "CAPTURE_DENIED",
                "Screen/audio capture permission was denied.",
                null,
            )
        }
    }

    private fun startCaptureService() {
        val intent =
            Intent(this, SystemAudioCaptureService::class.java)
                .putExtra(EXTRA_RESULT_CODE, projectionResultCode)
                .putExtra(EXTRA_RESULT_DATA, projectionResultData)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopCaptureService() {
        stopService(Intent(this, SystemAudioCaptureService::class.java))
    }
}
