package com.tanklink.tanklink

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The one place an alert becomes a notification, whichever way it arrived:
 * the background Bluetooth scan, or the app when it is open. It checks the
 * pump's tag (when there is one), shows each alert once, and says when some
 * were missed.
 */
object AlertNotifier {
    private const val CHANNEL = "alerts" // tank full, battery low, test
    private const val CHANNEL_URGENT = "alerts_urgent" // power cut, auto-off, sensor offline

    const val TANK_FULL = 1
    const val AUTO_OFF = 2
    const val POWER_CUT = 3
    const val TANK_OFFLINE = 4
    const val BATTERY_LOW = 5
    const val TEST = 6
    const val SENSOR_REMOVED = 7

    /** First 4 bytes of HMAC-SHA256(key, deviceId || seq || type || arg). Same as
     * make_tag in pump_node/main/pump_alert.c and alertTag in protocol.dart. */
    fun tag(pump: AlertStore.Pump, seq: Int, type: Int, arg: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(pump.key, "HmacSHA256"))
        mac.update(pump.deviceIdBytes())
        mac.update(byteArrayOf(seq.toByte(), type.toByte(), arg.toByte()))
        return mac.doFinal().copyOfRange(0, 4)
    }

    /** True if [tag] is the pump's own tag for this alert (constant time). */
    fun tagOk(pump: AlertStore.Pump, seq: Int, type: Int, arg: Int, tag: ByteArray): Boolean {
        val want = tag(pump, seq, type, arg)
        var diff = 0
        for (i in 0 until 4) diff = diff or (want[i].toInt() xor tag.getOrElse(i) { 0 }.toInt())
        return diff == 0
    }

    /**
     * Show an alert unless it was shown already. [tag] is null for alerts that
     * came over the app's signed-in connection (already trusted).
     * Returns true if a notification was posted.
     */
    fun handle(c: Context, pump: AlertStore.Pump, seq: Int, type: Int, arg: Int, tag: ByteArray?): Boolean {
        if (seq == 0) return false
        if (tag != null && !tagOk(pump, seq, type, arg, tag)) return false

        // New only if it is 1..127 ahead of the last one shown (so a late copy
        // of an old alert is ignored, and a wrap past 255 still counts).
        val last = AlertStore.lastSeq(c, pump.id)
        val ahead = (seq - last) and 0xFF
        if (last != 0 && (ahead < 1 || ahead > 127)) return false
        AlertStore.setLastSeq(c, pump.id, seq)
        val missed = if (last == 0) 0 else ahead - 1

        if (type != TEST && type !in AlertStore.types(c)) return false
        if (!AlertStore.enabled(c) && type != TEST) return false
        return post(c, pump, seq, type, arg, missed)
    }

    /** True while TankLink is on screen: it shows alerts itself then. */
    @Volatile var appVisible = false

    private fun tankName(p: AlertStore.Pump, slot: Int) = p.tanks.getOrNull(slot) ?: "Tank ${slot + 1}"

    private fun sensorName(p: AlertStore.Pump, i: Int) = p.sensors.getOrNull(i) ?: "Tank sensor ${i + 1}"

    /** Fill alerts: arg bits 0-2 the tank, bits 3-7 the run time in 5-minute steps. */
    private fun slotOf(arg: Int) = arg and 7

    /** "about 40 minutes", "about 1 h 15 min", "under 5 minutes", "over 2½ hours". */
    fun duration(arg: Int): String {
        val steps = (arg shr 3) and 31
        return when {
            steps == 0 -> "under 5 minutes"
            steps == 31 -> "over 2½ hours"
            else -> {
                val m = steps * 5
                if (m < 60) "about $m minutes"
                else "about ${m / 60} h${if (m % 60 == 0) "" else " ${m % 60} min"}"
            }
        }
    }

    /** "about 480 litres" from the pump's flow, or "" when it is unknown. */
    private fun litres(p: AlertStore.Pump, arg: Int): String {
        val flow = p.flowLpm ?: return ""
        val steps = (arg shr 3) and 31
        if (flow <= 0 || steps == 0 || steps == 31) return ""
        val l = Math.round(flow * steps * 5 / 10.0) * 10
        return if (l >= 10) ", about $l litres" else ""
    }

    private fun post(c: Context, p: AlertStore.Pump, seq: Int, type: Int, arg: Int, missed: Int): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        // On screen the app shows it already (a test always shows, to prove it works).
        if (appVisible && type != TEST) return false

        val tank = tankName(p, slotOf(arg))
        val (title, text) = when (type) {
            TANK_FULL -> "$tank is full" to "The pump stopped after ${duration(arg)}${litres(p, arg)}."
            AUTO_OFF -> "Auto-off stopped the pump" to
                "$tank ran for ${duration(arg)} and may not be full. Check the water supply."
            POWER_CUT -> "Power was cut during a fill" to
                "$tank had been filling for ${duration(arg)}. The pump won't restart on its own."
            TANK_OFFLINE -> "$tank: no signal from its sensor" to
                "The pump can't see the water level, but it still stops at auto-off. Check the sensor's battery and range."
            BATTERY_LOW -> "${sensorName(p, arg and 3)} battery at ${(arg shr 2) * 2}%" to
                "Charge it or check the solar panel soon."
            SENSOR_REMOVED -> "${sensorName(p, arg and 3)} removed" to
                "It went into pairing mode, so the pump dropped it. Pair it again if this wasn't you."
            TEST -> "Test alert" to "This is how a TankLink alert looks."
            else -> return false
        }
        val body = buildString {
            append(text)
            if (missed > 0) append(" And $missed more: open TankLink.")
        }
        // Things that need action get the louder channel.
        val urgent = type == POWER_CUT || type == AUTO_OFF || type == TANK_OFFLINE ||
            type == SENSOR_REMOVED
        val channel = if (urgent) CHANNEL_URGENT else CHANNEL

        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Pump updates", NotificationManager.IMPORTANCE_DEFAULT),
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_URGENT, "Pump problems", NotificationManager.IMPORTANCE_HIGH),
            )
        }
        val open = PendingIntent.getActivity(
            c,
            0,
            Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(c, channel)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setPriority(if (urgent) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentTitle(if (p.name.isNotBlank()) "${p.name}: $title" else title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        // One notification per pump: a new alert replaces the old one.
        NotificationManagerCompat.from(c).notify(p.id.hashCode(), n)
        return true
    }
}
