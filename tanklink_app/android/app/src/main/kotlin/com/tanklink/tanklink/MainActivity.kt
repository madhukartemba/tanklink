package com.tanklink.tanklink

import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.util.ArrayDeque

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call,
                result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("bad_arg", "path required", null)
                        return@setMethodCallHandler
                    }
                    val file = File(path)
                    if (!file.isFile) {
                        result.error("not_found", "APK not found", null)
                        return@setMethodCallHandler
                    }
                    val uri =
                        FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileProvider",
                            file,
                        )
                    val intent =
                        Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                    startActivity(intent)
                    result.success(true)
                }
                "openUrl" -> {
                    // https links only, opened in the browser (or GitHub app).
                    val url = call.argument<String>("url")
                    if (url == null || !url.startsWith("https://")) {
                        result.error("bad_arg", "https url required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(
                            Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error("no_app", "no app can open links", null)
                    }
                }
                "findPump" -> {
                    val id = call.argument<String>("id")
                    if (id.isNullOrBlank()) {
                        result.error("bad_arg", "id required", null)
                        return@setMethodCallHandler
                    }
                    findPump(id, (call.argument<Int>("timeoutMs") ?: 3000).toLong(), result)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Finds a pump on the home network by its mDNS record (_tanklink._tcp,
     * TXT id=<device id hex>) and answers its IPv4 address, or null after
     * [timeoutMs]. The app's fallback when the saved address no longer works.
     */
    private fun findPump(id: String, timeoutMs: Long, result: MethodChannel.Result) {
        val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        val main = Handler(Looper.getMainLooper())
        val lock = Any()
        val pending = ArrayDeque<NsdServiceInfo>()
        var resolving = false
        var done = false
        var discovery: NsdManager.DiscoveryListener? = null

        fun finish(ip: String?) {
            synchronized(lock) {
                if (done) return
                done = true
            }
            try {
                discovery?.let { nsd.stopServiceDiscovery(it) }
            } catch (_: Exception) {}
            main.post { result.success(ip) }
        }

        fun next() {
            val svc: NsdServiceInfo
            synchronized(lock) {
                if (done || resolving) return
                svc = pending.poll() ?: return
                resolving = true
            }
            nsd.resolveService(
                svc,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                        synchronized(lock) { resolving = false }
                        next()
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        synchronized(lock) { resolving = false }
                        val txt = info.attributes["id"]?.let { String(it) }
                        val host = info.host
                        if (txt != null && txt.equals(id, ignoreCase = true) &&
                            host is Inet4Address) {
                            finish(host.hostAddress)
                        } else {
                            next()
                        }
                    }
                },
            )
        }

        discovery =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {}
                override fun onDiscoveryStopped(type: String) {}
                override fun onStartDiscoveryFailed(type: String, code: Int) = finish(null)
                override fun onStopDiscoveryFailed(type: String, code: Int) {}
                override fun onServiceLost(info: NsdServiceInfo) {}
                override fun onServiceFound(info: NsdServiceInfo) {
                    synchronized(lock) { pending.add(info) }
                    next()
                }
            }
        try {
            nsd.discoverServices("_tanklink._tcp", NsdManager.PROTOCOL_DNS_SD, discovery)
        } catch (e: Exception) {
            finish(null)
            return
        }
        main.postDelayed({ finish(null) }, timeoutMs)
    }

    companion object {
        private const val CHANNEL = "com.tanklink/install"
    }
}