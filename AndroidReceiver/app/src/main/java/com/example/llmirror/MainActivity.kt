package com.example.llmirror

import android.app.Activity
import android.graphics.Color
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : Activity(), SurfaceHolder.Callback, StreamReceiver.Listener {

    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView

    private var decoder: VideoDecoder? = null
    private var receiver: StreamReceiver? = null
    private var nsd: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)

        surfaceView = SurfaceView(this)
        root.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        statusView = TextView(this)
        statusView.setTextColor(Color.WHITE)
        statusView.textSize = 26f
        statusView.gravity = Gravity.CENTER
        root.addView(
            statusView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        setContentView(root)
        hideSystemUi()
        surfaceView.holder.addCallback(this)
        showWaiting()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemUi() {
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    // ---- SurfaceHolder.Callback ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        val port = Proto.DEFAULT_PORT
        decoder = VideoDecoder(holder.surface) { w, h -> adjustAspect(w, h) }
        val r = StreamReceiver(port, this)
        receiver = r
        r.start()
        registerService(port)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        unregisterService()
        receiver?.stop()
        receiver = null
        decoder?.release()
        decoder = null
    }

    // ---- StreamReceiver.Listener ----

    override fun onConfig(codec: Int, paramSets: List<ByteArray>) {
        val ok = decoder?.configure(codec, paramSets) ?: false
        if (!ok) onError("Не удалось запустить декодер видео")
    }

    override fun onFrame(codec: Int, data: ByteArray, isKey: Boolean, timestampUs: Long): Boolean {
        return decoder?.queue(data, timestampUs, isKey) ?: false
    }

    override fun onStreamState(active: Boolean) {
        runOnUiThread {
            if (active) {
                statusView.visibility = View.GONE
            } else {
                showWaiting()
            }
        }
    }

    override fun onStop() {
        decoder?.release()
    }

    override fun onError(message: String) {
        runOnUiThread {
            statusView.text = message
            statusView.visibility = View.VISIBLE
        }
    }

    // ---- UI ----

    private fun showWaiting() {
        val ips = localIps()
        val ipLine = if (ips.isEmpty()) "IP не найден" else ips.joinToString("  /  ")
        statusView.text = "Ожидание трансляции с iPhone\n\n" +
            "Сеть: $ipLine\nПорт: ${Proto.DEFAULT_PORT}\n\n" +
            "Имя в списке на iPhone: ${serviceName()}"
        statusView.visibility = View.VISIBLE
    }

    private fun adjustAspect(w: Int, h: Int) {
        runOnUiThread {
            val rw = root.width
            val rh = root.height
            if (w <= 0 || h <= 0 || rw <= 0 || rh <= 0) return@runOnUiThread
            val scale = minOf(rw.toFloat() / w, rh.toFloat() / h)
            val lp = FrameLayout.LayoutParams(
                (w * scale).toInt(),
                (h * scale).toInt(),
                Gravity.CENTER
            )
            surfaceView.layoutParams = lp
        }
    }

    private fun localIps(): List<String> {
        return try {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .filter { it is Inet4Address && !it.isLoopbackAddress }
                .map { it.hostAddress ?: "" }
                .filter { it.isNotEmpty() }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun serviceName(): String = "Android TV (${Build.MODEL})"

    // ---- Bonjour / mDNS (чтобы iPhone находил приёмник сам) ----

    private fun registerService(port: Int) {
        try {
            val info = NsdServiceInfo()
            info.serviceName = serviceName()
            info.serviceType = Proto.SERVICE_TYPE
            info.port = port

            val listener = object : NsdManager.RegistrationListener {
                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {}
                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            }
            val mgr = getSystemService(NSD_SERVICE) as NsdManager
            mgr.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            nsd = mgr
            nsdListener = listener
        } catch (_: Exception) {
        }
    }

    private fun unregisterService() {
        try {
            val l = nsdListener
            if (l != null) nsd?.unregisterService(l)
        } catch (_: Exception) {
        }
        nsdListener = null
        nsd = null
    }
}
