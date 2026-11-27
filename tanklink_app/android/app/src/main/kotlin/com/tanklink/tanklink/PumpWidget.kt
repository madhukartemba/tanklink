package com.tanklink.tanklink

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.os.SystemClock
import android.text.format.DateFormat
import android.view.View
import android.widget.RemoteViews

/** Home screen widget: the selected pump, running or not, its tank. Tap to open. */
class PumpWidget : AppWidgetProvider() {
    override fun onUpdate(c: Context, m: AppWidgetManager, ids: IntArray) {
        val views = build(c)
        for (id in ids) m.updateAppWidget(id, views)
    }

    companion object {
        fun refreshAll(c: Context) {
            val m = AppWidgetManager.getInstance(c)
            val ids = m.getAppWidgetIds(ComponentName(c, PumpWidget::class.java))
            if (ids.isEmpty()) return
            val views = build(c)
            for (id in ids) m.updateAppWidget(id, views)
        }

        private fun build(c: Context): RemoteViews {
            val s = PumpGlance.load(c)
            val v = RemoteViews(c.packageName, R.layout.pump_widget)
            v.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    c,
                    1,
                    PumpGlance.openIntent(c, s?.serial),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            if (s == null) {
                v.setTextViewText(R.id.widget_name, "TankLink")
                v.setTextViewText(R.id.widget_status, "Add a pump")
                v.setTextColor(R.id.widget_status, c.getColor(R.color.widget_fg))
                v.setViewVisibility(R.id.widget_timer, View.GONE)
                v.setViewVisibility(R.id.widget_tank, View.GONE)
                v.setViewVisibility(R.id.widget_seen, View.GONE)
                v.setContentDescription(R.id.widget_root, "TankLink. Add a pump.")
                return v
            }
            val known = s.at > 0
            val status = when {
                !known -> "Not connected"
                s.on -> "Running"
                else -> "Stopped"
            }
            v.setTextViewText(R.id.widget_name, s.name)
            v.setTextViewText(R.id.widget_status, status)
            v.setTextColor(
                R.id.widget_status,
                c.getColor(if (s.on && known) R.color.widget_accent else R.color.widget_fg),
            )
            // The run timer ticks by itself (Chronometer), only while live.
            if (s.on && s.live && s.runStart > 0) {
                val base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - s.runStart)
                v.setChronometer(R.id.widget_timer, base, null, true)
                v.setViewVisibility(R.id.widget_timer, View.VISIBLE)
            } else {
                v.setChronometer(R.id.widget_timer, SystemClock.elapsedRealtime(), null, false)
                v.setViewVisibility(R.id.widget_timer, View.GONE)
            }
            v.setTextViewText(R.id.widget_tank, s.tank)
            v.setViewVisibility(R.id.widget_tank, if (s.tank.isEmpty() || !known) View.GONE else View.VISIBLE)
            val seen = if (s.live || !known) "" else "As of " + DateFormat.getTimeFormat(c).format(s.at)
            v.setTextViewText(R.id.widget_seen, seen)
            v.setViewVisibility(R.id.widget_seen, if (seen.isEmpty()) View.GONE else View.VISIBLE)
            v.setContentDescription(
                R.id.widget_root,
                listOf(s.name, status, s.tank.takeIf { known }, seen).filter { !it.isNullOrEmpty() }.joinToString(". "),
            )
            return v
        }
    }
}
