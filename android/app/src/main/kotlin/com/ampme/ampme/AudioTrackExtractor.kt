package com.ampme.ampme

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import java.io.File
import java.nio.ByteBuffer

/**
 * Copies a video's sound track into an audio-only file — no re-encoding, so
 * it is fast and lossless. Phones in a session only play the sound; giving
 * them the whole video wastes bandwidth and makes them demux a picture nobody
 * sees (which starved their audio output in testing).
 */
object AudioTrackExtractor {
    /**
     * Writes the first audio track of [inputPath] to a file in [outDir] and
     * returns its path, or null if the video has no sound or its codec can't
     * be stored in a container this Android version can write (the caller
     * then falls back to the original file).
     */
    fun extract(inputPath: String, outDir: File): String? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(inputPath)
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) return null
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val (muxerFormat, ext) = when (mime) {
                MediaFormat.MIMETYPE_AUDIO_AAC -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4 to "m4a"
                MediaFormat.MIMETYPE_AUDIO_OPUS, MediaFormat.MIMETYPE_AUDIO_VORBIS ->
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM to "webm"
                else -> return null
            }
            if (mime == MediaFormat.MIMETYPE_AUDIO_OPUS && Build.VERSION.SDK_INT < 29) return null

            outDir.mkdirs()
            val out = File(outDir, "sound_${System.currentTimeMillis()}.$ext")
            val muxer = MediaMuxer(out.path, muxerFormat)
            try {
                val dst = muxer.addTrack(format)
                muxer.start()
                extractor.selectTrack(trackIndex)
                val maxSize = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
                } else {
                    256 * 1024
                }
                val buffer = ByteBuffer.allocate(maxOf(maxSize, 64 * 1024))
                val info = MediaCodec.BufferInfo()
                while (true) {
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = extractor.sampleTime
                    info.flags = if ((extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) {
                        MediaCodec.BUFFER_FLAG_KEY_FRAME
                    } else {
                        0
                    }
                    muxer.writeSampleData(dst, buffer, info)
                    extractor.advance()
                }
                muxer.stop()
            } finally {
                try {
                    muxer.release()
                } catch (_: Exception) {
                }
            }
            return out.path
        } finally {
            extractor.release()
        }
    }
}
