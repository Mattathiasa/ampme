package com.ampme.ampme

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Tells Dart where media sound is coming out (phone speaker, wired,
 * Bluetooth...) and when that changes, so a sync calibration can be kept per
 * speaker: a Bluetooth speaker sounds 150-300 ms later than the phone's own.
 */
class AudioRouteMonitor(context: Context, private val channel: MethodChannel) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var lastKey: String? = null
    private var watching = false

    private val callback =
        object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = check()

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = check()
        }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "current" -> result.success(current())
                "watch" -> {
                    if (call.arguments == true) start() else stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start() {
        if (watching) return
        watching = true
        lastKey = current()["key"] as String?
        audio.registerAudioDeviceCallback(callback, main)
    }

    private fun stop() {
        if (!watching) return
        watching = false
        audio.unregisterAudioDeviceCallback(callback)
    }

    private fun check() {
        // The route settles a moment after the device list changes.
        main.postDelayed({
            if (!watching) return@postDelayed
            val now = current()
            if (now["key"] != lastKey) {
                lastKey = now["key"] as String?
                channel.invokeMethod("changed", now)
            }
        }, 400)
    }

    fun current(): Map<String, Any> {
        val device = routedDevice() ?: return describe(null)
        return describe(device)
    }

    /** The output media actually plays through (API 33+), else the likeliest. */
    private fun routedDevice(): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT >= 33) {
            val media =
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            audio.getAudioDevicesForAttributes(media).firstOrNull()?.let { return it }
        }
        val outputs = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.minByOrNull { rank(it.type) }
    }

    private fun rank(type: Int): Int =
        when {
            isBluetooth(type) -> 0
            isWired(type) -> 1
            type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> 2
            else -> 3
        }

    private fun isBluetooth(type: Int): Boolean =
        type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
            type == AudioDeviceInfo.TYPE_HEARING_AID ||
            (Build.VERSION.SDK_INT >= 31 &&
                (type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    type == AudioDeviceInfo.TYPE_BLE_SPEAKER)) ||
            (Build.VERSION.SDK_INT >= 33 && type == AudioDeviceInfo.TYPE_BLE_BROADCAST)

    private fun isWired(type: Int): Boolean =
        type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
            type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
            type == AudioDeviceInfo.TYPE_USB_HEADSET ||
            type == AudioDeviceInfo.TYPE_USB_DEVICE ||
            type == AudioDeviceInfo.TYPE_LINE_ANALOG ||
            type == AudioDeviceInfo.TYPE_LINE_DIGITAL

    private fun describe(device: AudioDeviceInfo?): Map<String, Any> {
        val type = device?.type ?: AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        val name = device?.productName?.toString()?.trim().orEmpty()
        return when {
            isBluetooth(type) -> {
                val label = name.ifEmpty { "Bluetooth" }
                mapOf("key" to "bt:$label", "label" to label, "bluetooth" to true)
            }
            isWired(type) -> mapOf("key" to "wired", "label" to "Headphones / cable", "bluetooth" to false)
            type == AudioDeviceInfo.TYPE_HDMI || type == AudioDeviceInfo.TYPE_HDMI_ARC ->
                mapOf("key" to "hdmi", "label" to "HDMI", "bluetooth" to false)
            else -> mapOf("key" to "speaker", "label" to "Phone speaker", "bluetooth" to false)
        }
    }
}
