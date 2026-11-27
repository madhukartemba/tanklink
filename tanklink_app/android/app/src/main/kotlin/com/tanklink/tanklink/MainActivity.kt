package com.tanklink.tanklink

import android.content.Context
import android.content.Intent
import android.os.Build
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.util.ArrayDeque

class MainActivity : FlutterActivity() {
    // Alerts aren't shown as notifications while the app is on screen: the app
    // already shows them (see AlertNotifier.appVisible).
    override fun onResume() {
        super.onResume()
        AlertNotifier.appVisible = true
    }

    override fun onPause() {
        AlertNotifier.appVisible = false
        super.onPause()
    }

    // lib/link/app_link.dart: the App Link the app was opened with (given to
    // Dart once) and the ones that arrive while it runs.
    private var linkChannel: MethodChannel? = null
    private var initialLink: String? = null

    private fun appLink(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_VIEW) intent.dataString else null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        appLink(intent)?.let { linkChannel?.invokeMethod("link", it) }
    }

    /** Long-press the app icon: one shortcut per saved pump (the launcher shows about 4). */
    private fun setPumpShortcuts(pumps: List<Map<String, String>>) {
        val max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(this)
        val list = pumps.take(max).mapIndexed { i, p ->
            val serial = p["serial"]!!
            val name = p["name"]!!
            ShortcutInfoCompat.Builder(this, "pump-$serial")
                .setShortLabel(name)
                .setLongLabel("Open $name")
                .setIcon(IconCompat.createWithResource(this, R.mipmap.ic_launcher))
                .setRank(i)
                .setIntent(
                    Intent(Intent.ACTION_VIEW, android.net.Uri.parse("$LINK_BASE/pump/$serial"))
                        .setClass(this, MainActivity::class.java),
                )
                .build()
        }
        ShortcutManagerCompat.setDynamicShortcuts(this, list)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialLink = appLink(intent)
        linkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LINK_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "initialLink") {
                    result.success(initialLink)
                    initialLink = null
                } else if (call.method == "setShortcuts") {
                    @Suppress("UNCHECKED_CAST")
                    setPumpShortcuts(call.arguments as List<Map<String, String>>)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GLANCE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "update") {
                    @Suppress("UNCHECKED_CAST")
                    PumpGlance.save(this, call.arguments as Map<String, Any?>)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HAPTICS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "play") {
                    Haptics.play(
                        this,
                        call.argument<String>("name") ?: "tap",
                        (call.argument<Double>("scale") ?: 1.0).toFloat(),
                    )
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALERTS_CHANNEL)
            .setMethodCallHandler { call, result -> handleAlerts(call, result) }
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

    /** lib/alerts/alert_bridge.dart: what the background alert code needs. */
    private fun handleAlerts(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(AlertScanner.supported())
            "syncPumps" -> {
                val list = call.argument<List<Map<String, Any?>>>("pumps") ?: emptyList()
                val pumps = list.mapNotNull { m ->
                    val key = AlertStore.hex(m["key"] as? String ?: "")
                    if (key.size != 16) return@mapNotNull null
                    @Suppress("UNCHECKED_CAST")
                    AlertStore.Pump(
                        m["id"] as String,
                        m["mac"] as String,
                        m["name"] as String,
                        key,
                        (m["tanks"] as? List<String>) ?: emptyList(),
                        (m["sensors"] as? List<String>) ?: emptyList(),
                        (m["flow"] as? Number)?.toDouble(),
                    )
                }
                AlertStore.setPumps(this, pumps)
                AlertScanner.register(this)
                result.success(true)
            }
            "setEnabled" -> {
                AlertStore.setEnabled(this, call.argument<Boolean>("on") ?: false)
                AlertScanner.register(this)
                result.success(true)
            }
            "isEnabled" -> result.success(AlertStore.enabled(this))
            "setTypes" -> {
                AlertStore.setTypes(this, call.argument<List<Int>>("types") ?: emptyList())
                result.success(true)
            }
            "types" -> result.success(AlertStore.types(this).toList())
            "showAlert" -> {
                // The app saw an alert over its own connection (trusted: no tag).
                val id = call.argument<String>("id") ?: ""
                val pump = AlertStore.pumps(this).firstOrNull { it.id.equals(id, ignoreCase = true) }
                if (pump == null) {
                    result.success(false)
                    return
                }
                result.success(
                    AlertNotifier.handle(
                        this,
                        pump,
                        call.argument<Int>("seq") ?: 0,
                        call.argument<Int>("type") ?: 0,
                        call.argument<Int>("arg") ?: 0,
                        null,
                    ),
                )
            }
            "permissions" -> {
                val notif = Build.VERSION.SDK_INT < 33 ||
                    checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                result.success(mapOf("notifications" to notif, "scan" to AlertScanner.hasScanPermission(this)))
            }
            "requestPermissions" -> {
                val need = mutableListOf<String>()
                if (Build.VERSION.SDK_INT >= 33) need.add(android.Manifest.permission.POST_NOTIFICATIONS)
                if (Build.VERSION.SDK_INT >= 31) need.add(android.Manifest.permission.BLUETOOTH_SCAN)
                if (need.isNotEmpty()) requestPermissions(need.toTypedArray(), 7)
                result.success(true)
            }
            "batteryUnrestricted" -> {
                val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(packageName))
            }
            "openNotificationSettings" -> {
                startActivity(
                    Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(true)
            }
            "openBatterySettings" -> {
                startActivity(
                    Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(android.net.Uri.parse("package:$packageName"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val CHANNEL = "com.tanklink/install"
        private const val ALERTS_CHANNEL = "tanklink/alerts"
        private const val LINK_CHANNEL = "com.tanklink/link"
        private const val HAPTICS_CHANNEL = "com.tanklink/haptics"
        private const val GLANCE_CHANNEL = "com.tanklink/glance"
        const val LINK_BASE = "https://tanklink.madhukartemba.in"
    }
}