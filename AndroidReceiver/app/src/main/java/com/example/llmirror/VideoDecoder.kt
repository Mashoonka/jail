package com.example.llmirror

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import java.nio.ByteBuffer

/** Аппаратный декодер H.264/HEVC с выводом сразу на Surface (минимальная задержка). */
class VideoDecoder(
    private val surface: Surface,
    private val onSize: (Int, Int) -> Unit
) {

    private class Session(val codec: MediaCodec) {
        @Volatile
        var alive = true
        var thread: Thread? = null
    }

    private var session: Session? = null
    private var curType = 0
    private var curSets: List<ByteArray>? = null

    @Synchronized
    fun configure(type: Int, sets: List<ByteArray>): Boolean {
        if (session != null && type == curType && sameSets(sets, curSets)) return true
        releaseLocked()
        if (sets.isEmpty()) return false

        val mime = if (type == Proto.CODEC_HEVC) "video/hevc" else "video/avc"
        val start = byteArrayOf(0, 0, 0, 1)
        return try {
            val fmt = MediaFormat.createVideoFormat(mime, 1920, 1080)
            if (type == Proto.CODEC_HEVC) {
                var all = ByteArray(0)
                for (s in sets) all = all + start + s
                fmt.setByteBuffer("csd-0", ByteBuffer.wrap(all))
            } else {
                fmt.setByteBuffer("csd-0", ByteBuffer.wrap(start + sets[0]))
                if (sets.size > 1) fmt.setByteBuffer("csd-1", ByteBuffer.wrap(start + sets[1]))
            }
            if (Build.VERSION.SDK_INT >= 30) {
                fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            fmt.setInteger(MediaFormat.KEY_PRIORITY, 0)

            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(fmt, surface, null, 0)
            codec.start()

            val s = Session(codec)
            s.thread = Thread({ drain(s) }, "llm-dec-out").apply {
                isDaemon = true
                start()
            }
            session = s
            curType = type
            curSets = sets
            true
        } catch (e: Exception) {
            session = null
            false
        }
    }

    @Synchronized
    fun queue(data: ByteArray, timestampUs: Long, key: Boolean): Boolean {
        val s = session ?: return false
        return try {
            val i = s.codec.dequeueInputBuffer(4000)
            if (i < 0) return false
            val buf = s.codec.getInputBuffer(i) ?: return false
            buf.clear()
            if (data.size > buf.capacity()) {
                s.codec.queueInputBuffer(i, 0, 0, timestampUs, 0)
                return false
            }
            buf.put(data, 0, data.size)
            val flags = if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            s.codec.queueInputBuffer(i, 0, data.size, timestampUs, flags)
            true
        } catch (e: Exception) {
            false
        }
    }

    @Synchronized
    fun release() {
        releaseLocked()
    }

    private fun releaseLocked() {
        val s = session ?: return
        session = null
        curSets = null
        curType = 0
        s.alive = false
        try {
            s.codec.stop()
        } catch (_: Exception) {
        }
        try {
            s.codec.release()
        } catch (_: Exception) {
        }
        try {
            s.thread?.join(300)
        } catch (_: Exception) {
        }
    }

    private fun drain(s: Session) {
        val info = MediaCodec.BufferInfo()
        while (s.alive) {
            try {
                val idx = s.codec.dequeueOutputBuffer(info, 10_000)
                if (idx >= 0) {
                    // true = показать кадр сразу, не дожидаясь временной метки
                    s.codec.releaseOutputBuffer(idx, true)
                } else if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    reportSize(s.codec.outputFormat)
                }
            } catch (e: Exception) {
                break
            }
        }
    }

    private fun reportSize(f: MediaFormat) {
        try {
            val w = if (f.containsKey("crop-right") && f.containsKey("crop-left")) {
                f.getInteger("crop-right") - f.getInteger("crop-left") + 1
            } else {
                f.getInteger(MediaFormat.KEY_WIDTH)
            }
            val h = if (f.containsKey("crop-bottom") && f.containsKey("crop-top")) {
                f.getInteger("crop-bottom") - f.getInteger("crop-top") + 1
            } else {
                f.getInteger(MediaFormat.KEY_HEIGHT)
            }
            onSize(w, h)
        } catch (_: Exception) {
        }
    }

    private fun sameSets(a: List<ByteArray>, b: List<ByteArray>?): Boolean {
        if (b == null || a.size != b.size) return false
        for (i in a.indices) {
            if (!a[i].contentEquals(b[i])) return false
        }
        return true
    }
}
