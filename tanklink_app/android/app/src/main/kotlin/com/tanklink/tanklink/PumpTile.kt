package com.tanklink.tanklink

import android.app.PendingIntent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.text.format.DateFormat

/**
 * Quick Settings tile: shows whether the selected pump is running; a tap
 * opens the app on it. Starting still takes the app's slider, and stopping
 * needs the app's connection, so the tile doesn't switch the pump itself.
 */
class PumpTile : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val t = qsTile ?: return
        val s = PumpGlance.load(this)
        t.icon = Icon.createWithResource(this, R.drawable.ic_stat_tanklink)
        if (s == null) {
            t.label = "TankLink"
            t.state = Tile.STATE_INACTIVE
            if (Build.VERSION.SDK_INT >= 29) t.subtitle = "Add a pump"
        } else {
            val known = s.at > 0
            t.label = s.name
            t.state = if (known && s.on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            val sub = when {
                !known -> "Not connected"
                !s.live -> (if (s.on) "Running" else "Stopped") + " · " + DateFormat.getTimeFormat(this).format(s.at)
                s.on -> "Running"
                else -> "Stopped"
            }
            if (Build.VERSION.SDK_INT >= 29) t.subtitle = sub
            t.contentDescription = "${s.name}, $sub"
        }
        t.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { open() } else open()
    }

    private fun open() {
        val intent = PumpGlance.openIntent(this, PumpGlance.load(this)?.serial)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 2, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}
