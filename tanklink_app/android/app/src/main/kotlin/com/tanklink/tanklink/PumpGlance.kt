package com.tanklink.tanklink

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.service.quicksettings.TileService

/**
 * The selected pump's last known state, for the home screen widget
 * (PumpWidget) and the Quick Settings tile (PumpTile). The app sends it
 * (lib/glance/glance_bridge.dart) whenever it changes; while the app is
 * closed it stays as last seen, with the time.
 */
object PumpGlance {
    private const val PREFS = "tanklink_glance"

    data class State(
        val serial: String,
        val name: String,
        /** Connected now (else the rest is as of [at]). */
        val live: Boolean,
        val on: Boolean,
        /** When the current run started (ms since epoch), for the run timer. */
        val runStart: Long,
        /** "Tank 1 · Full", or empty without a tank sensor. */
        val tank: String,
        val at: Long,
    )

    fun load(c: Context): State? {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val serial = p.getString("serial", null) ?: return null
        return State(
            serial,
            p.getString("name", "") ?: "",
            p.getBoolean("live", false),
            p.getBoolean("on", false),
            p.getLong("runStart", 0),
            p.getString("tank", "") ?: "",
            p.getLong("at", 0),
        )
    }

    /**
     * [m]: serial and name always; live, on, runStart, tank and at only when
     * connected. A different serial (another pump) starts from scratch; a
     * missing serial (no pumps) clears it.
     */
    fun save(c: Context, m: Map<String, Any?>) {
        val p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val serial = m["serial"] as String?
        val e = p.edit()
        if (serial == null) {
            e.clear()
        } else {
            if (serial != p.getString("serial", null)) e.clear()
            e.putString("serial", serial)
            e.putString("name", m["name"] as String)
            val live = m["live"] as Boolean
            e.putBoolean("live", live)
            if (live) {
                e.putBoolean("on", m["on"] as Boolean)
                e.putLong("runStart", (m["runStart"] as Number).toLong())
                e.putString("tank", m["tank"] as String)
                e.putLong("at", (m["at"] as Number).toLong())
            }
        }
        e.apply()
        PumpWidget.refreshAll(c)
        TileService.requestListeningState(c, ComponentName(c, PumpTile::class.java))
    }

    /** Opens the app on [serial]'s pump (the same App Link as its NFC tag). */
    fun openIntent(c: Context, serial: String?): Intent =
        Intent(
            Intent.ACTION_VIEW,
            Uri.parse(if (serial == null) "${MainActivity.LINK_BASE}/pump" else "${MainActivity.LINK_BASE}/pump/$serial"),
        ).setClass(c, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
}
