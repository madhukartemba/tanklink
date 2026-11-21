package com.tanklink.tanklink

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * What the alert code needs, kept here (not in Flutter) because the background
 * receiver runs without the Flutter engine. Flutter pushes it in with
 * `syncPumps`, `setEnabled` and `setTypes` (lib/alerts/alert_bridge.dart).
 */
object AlertStore {
    class Pump(
        val id: String, // device id, 12 hex digits
        val mac: String, // the phone's BLE address for it
        val name: String,
        val key: ByteArray, // the pump's alert key
        val tanks: List<String>, // tank names by slot
        val sensors: List<String>, // sensor names by index
    ) {
        fun deviceIdBytes(): ByteArray =
            ByteArray(id.length / 2) { id.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    private const val PREFS = "tanklink_alerts"
    // Alert types 1..5 notify by default (6, the test, always does).
    private val DEFAULT_TYPES = setOf(1, 2, 3, 4, 5)

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun enabled(c: Context) = prefs(c).getBoolean("enabled", false)

    fun setEnabled(c: Context, on: Boolean) = prefs(c).edit().putBoolean("enabled", on).apply()

    fun types(c: Context): Set<Int> {
        val raw = prefs(c).getString("types", null) ?: return DEFAULT_TYPES
        val arr = JSONArray(raw)
        return (0 until arr.length()).map { arr.getInt(it) }.toSet()
    }

    fun setTypes(c: Context, types: List<Int>) =
        prefs(c).edit().putString("types", JSONArray(types).toString()).apply()

    fun pumps(c: Context): List<Pump> {
        val raw = prefs(c).getString("pumps", null) ?: return emptyList()
        val arr = JSONArray(raw)
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.getJSONObject(i)
            val key = hex(o.getString("key"))
            if (key.size != 16) return@mapNotNull null
            Pump(
                o.getString("id"),
                o.getString("mac"),
                o.getString("name"),
                key,
                strings(o.getJSONArray("tanks")),
                strings(o.getJSONArray("sensors")),
            )
        }
    }

    fun setPumps(c: Context, pumps: List<Pump>) {
        val arr = JSONArray()
        for (p in pumps) {
            arr.put(
                JSONObject()
                    .put("id", p.id)
                    .put("mac", p.mac)
                    .put("name", p.name)
                    .put("key", p.key.joinToString("") { "%02x".format(it) })
                    .put("tanks", JSONArray(p.tanks))
                    .put("sensors", JSONArray(p.sensors)),
            )
        }
        prefs(c).edit().putString("pumps", arr.toString()).apply()
    }

    /** The last alert number shown for a pump (0 = none yet). */
    fun lastSeq(c: Context, pumpId: String) = prefs(c).getInt("seq_$pumpId", 0)

    fun setLastSeq(c: Context, pumpId: String, seq: Int) =
        prefs(c).edit().putInt("seq_$pumpId", seq).apply()

    private fun strings(a: JSONArray) = (0 until a.length()).map { a.getString(it) }

    fun hex(s: String): ByteArray =
        if (s.length % 2 != 0) ByteArray(0)
        else ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
