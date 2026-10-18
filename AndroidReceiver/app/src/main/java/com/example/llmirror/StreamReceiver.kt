package com.example.llmirror

import android.os.SystemClock
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer

/**
 * Принимает UDP-пакеты от iPhone, собирает кадры из фрагментов,
 * переводит AVCC -> Annex-B и отвечает на Ping/PLI.
 */
class StreamReceiver(
    private val port: Int,
    private val listener: Listener
) {

    interface Listener {
        fun onConfig(codec: Int, paramSets: List<ByteArray>)

        /** Возвращает false, если декодер не смог принять кадр (тогда запросим новый ключевой кадр). */
        fun onFrame(codec: Int, data: ByteArray, isKey: Boolean, timestampUs: Long): Boolean
        fun onStreamState(active: Boolean)
        fun onStop()
        fun onError(message: String)
    }

    private class Assembly(val type: Int, val codec: Int, val ts: Long, val count: Int) {
        val parts = arrayOfNulls<ByteArray>(count)
        var got = 0
        var bytes = 0
    }

    @Volatile
    private var running = false
    private var socket: DatagramSocket? = null
    private var thread: Thread? = null

    @Volatile
    private var peer: SocketAddress? = null

    private val pending = LinkedHashMap<Long, Assembly>()
    private var needKey = true
    private var lastPliMs = 0L
    private var outSeq = 0L
    private var received = 0L
    private var lost = 0L
    private var lastSeq = -1L
    private var delivered = 0L
    private var deliveredAtLastSec = 0L
    private var fps = 0
    private var lastFpsMs = 0L
    private var lastVideoMs = 0L
    private var streaming = false

    fun start() {
        if (running) return
        val s: DatagramSocket = try {
            DatagramSocket(null as SocketAddress?).apply {
                reuseAddress = true
                receiveBufferSize = 4 * 1024 * 1024
                soTimeout = 200
                bind(InetSocketAddress(port))
            }
        } catch (e: Exception) {
            listener.onError("Не удалось открыть порт $port: ${e.message}")
            return
        }
        socket = s
        running = true
        thread = Thread({ loop(s) }, "llm-recv").apply {
            isDaemon = true
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    fun stop() {
        running = false
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        try {
            thread?.join(500)
        } catch (_: Exception) {
        }
        socket = null
        thread = null
        peer = null
        resetStream()
    }

    private fun resetStream() {
        pending.clear()
        needKey = true
        lastSeq = -1L
        received = 0L
        lost = 0L
        streaming = false
    }

    private fun loop(sock: DatagramSocket) {
        val buf = ByteArray(2048)
        val pkt = DatagramPacket(buf, buf.size)
        while (running) {
            try {
                pkt.setData(buf, 0, buf.size)
                sock.receive(pkt)
                handle(buf, pkt)
            } catch (_: SocketTimeoutException) {
                // нормально: просто проверяем таймеры ниже
            } catch (e: Exception) {
                if (!running) break
            }
            try {
                maybeSendPli()
                tick()
            } catch (_: Exception) {
            }
        }
    }

    private fun tick() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastFpsMs >= 1000) {
            fps = (delivered - deliveredAtLastSec).toInt()
            deliveredAtLastSec = delivered
            lastFpsMs = now
        }
        if (streaming && now - lastVideoMs > 3000) {
            streaming = false
            needKey = true
            listener.onStreamState(false)
        }
    }

    private fun handle(buf: ByteArray, pkt: DatagramPacket) {
        val len = pkt.length
        if (len < Proto.HEADER) return
        if ((buf[0].toInt() and 0xFF) != Proto.MAGIC) return

        val type = buf[1].toInt() and 0xFF
        val flags = buf[2].toInt() and 0xFF
        val codec = flags and 0x0F
        val bb = ByteBuffer.wrap(buf, 0, len)
        val seq = bb.getInt(4).toLong() and MASK
        val frameNo = bb.getInt(8).toLong() and MASK
        val fragIdx = bb.getShort(12).toInt() and 0xFFFF
        val fragCnt = bb.getShort(14).toInt() and 0xFFFF
        val ts = bb.getLong(16)

        peer = pkt.socketAddress
        trackSequence(seq)

        when (type) {
            Proto.T_PING -> sendPong(ts)
            Proto.T_STOP -> {
                resetStream()
                listener.onStop()
                listener.onStreamState(false)
            }
            Proto.T_CONFIG, Proto.T_IDR, Proto.T_SLICE -> {
                if (fragCnt == 0 || fragCnt > 4096 || fragIdx >= fragCnt) return
                val key = (frameNo shl 8) or type.toLong()
                val asm = pending.getOrPut(key) { Assembly(type, codec, ts, fragCnt) }
                if (asm.count != fragCnt) return
                if (asm.parts[fragIdx] == null) {
                    asm.parts[fragIdx] = buf.copyOfRange(Proto.HEADER, len)
                    asm.got++
                    asm.bytes += len - Proto.HEADER
                }
                if (asm.got == asm.count) {
                    pending.remove(key)
                    complete(frameNo, asm)
                }
                while (pending.size > 12) {
                    val it = pending.entries.iterator()
                    it.next()
                    it.remove()
                    needKey = true
                }
            }
            else -> { /* звук и прочее пока пропускаем */ }
        }
    }

    private fun trackSequence(seq: Long) {
        received++
        if (lastSeq < 0) {
            lastSeq = seq
            return
        }
        val d = (seq - lastSeq) and MASK
        if (d == 0L) return
        if (d < 0x80000000L) {
            if (d <= 1000) {
                lost += d - 1
            } else {
                // похоже, поток перезапустили
                pending.clear()
                needKey = true
            }
            lastSeq = seq
        }
    }

    private fun complete(frameNo: Long, asm: Assembly) {
        val data = ByteArray(asm.bytes)
        var off = 0
        for (p in asm.parts) {
            val part = p ?: return
            System.arraycopy(part, 0, data, off, part.size)
            off += part.size
        }

        when (asm.type) {
            Proto.T_CONFIG -> {
                val sets = parseConfig(data) ?: return
                listener.onConfig(asm.codec, sets)
            }
            Proto.T_IDR, Proto.T_SLICE -> {
                // Более старые, но так и не собранные видеокадры считаем потерянными
                val it = pending.entries.iterator()
                while (it.hasNext()) {
                    val e = it.next()
                    val fno = e.key shr 8
                    val t = (e.key and 0xFF).toInt()
                    if ((t == Proto.T_IDR || t == Proto.T_SLICE) &&
                        ((frameNo - fno) and MASK) in 1L..1_000_000L
                    ) {
                        it.remove()
                        needKey = true
                    }
                }

                val isKey = asm.type == Proto.T_IDR
                if (isKey) needKey = false
                if (needKey) return
                if (!avccToAnnexB(data)) {
                    needKey = true
                    return
                }
                val ok = listener.onFrame(asm.codec, data, isKey, asm.ts)
                if (ok) {
                    delivered++
                    lastVideoMs = SystemClock.elapsedRealtime()
                    if (!streaming) {
                        streaming = true
                        listener.onStreamState(true)
                    }
                } else {
                    needKey = true
                }
            }
        }
    }

    /** Блок параметров: [count u8] затем count раз [len u16 BE][bytes]. */
    private fun parseConfig(d: ByteArray): List<ByteArray>? {
        if (d.isEmpty()) return null
        val count = d[0].toInt() and 0xFF
        var p = 1
        val out = ArrayList<ByteArray>()
        for (i in 0 until count) {
            if (p + 2 > d.size) return null
            val l = ((d[p].toInt() and 0xFF) shl 8) or (d[p + 1].toInt() and 0xFF)
            p += 2
            if (l <= 0 || p + l > d.size) return null
            out.add(d.copyOfRange(p, p + l))
            p += l
        }
        return out
    }

    /** Заменяет 4-байтные длины NAL-юнитов на стартовый код 00 00 00 01 (размер не меняется). */
    private fun avccToAnnexB(d: ByteArray): Boolean {
        var p = 0
        while (p + 4 <= d.size) {
            val n = ((d[p].toInt() and 0xFF) shl 24) or
                ((d[p + 1].toInt() and 0xFF) shl 16) or
                ((d[p + 2].toInt() and 0xFF) shl 8) or
                (d[p + 3].toInt() and 0xFF)
            if (n <= 0 || p + 4 + n > d.size) return false
            d[p] = 0
            d[p + 1] = 0
            d[p + 2] = 0
            d[p + 3] = 1
            p += 4 + n
        }
        return p == d.size
    }

    private fun maybeSendPli() {
        if (!needKey) return
        val target = peer ?: return
        val now = SystemClock.elapsedRealtime()
        if (now - lastPliMs < 300) return
        lastPliMs = now
        val b = ByteArray(Proto.HEADER)
        writeHeader(b, Proto.T_PLI)
        send(b, target)
    }

    private fun sendPong(originalPingTs: Long) {
        val target = peer ?: return
        val b = ByteArray(Proto.HEADER + 18)
        writeHeader(b, Proto.T_PONG)
        val bb = ByteBuffer.wrap(b)
        bb.putLong(24, originalPingTs)
        bb.putInt(32, received.toInt())
        bb.putInt(36, lost.toInt())
        bb.putShort(40, fps.toShort())
        send(b, target)
    }

    private fun writeHeader(b: ByteArray, type: Int) {
        outSeq++
        val bb = ByteBuffer.wrap(b)
        b[0] = Proto.MAGIC.toByte()
        b[1] = type.toByte()
        b[2] = 0x81.toByte()
        b[3] = 0
        bb.putInt(4, outSeq.toInt())
        bb.putInt(8, 0)
        bb.putShort(12, 0)
        bb.putShort(14, 1)
        bb.putLong(16, SystemClock.elapsedRealtimeNanos() / 1000L)
    }

    private fun send(b: ByteArray, target: SocketAddress) {
        try {
            socket?.send(DatagramPacket(b, b.size, target))
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val MASK = 0xFFFFFFFFL
    }
}
