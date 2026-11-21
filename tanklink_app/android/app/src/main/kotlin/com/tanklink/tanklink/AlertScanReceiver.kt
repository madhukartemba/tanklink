package com.tanklink.tanklink

import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** Android hands a pump's alert advertisement here, even with the app closed. */
class AlertScanReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val results: List<ScanResult> =
            if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(
                    BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT,
                    ScanResult::class.java,
                )
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT)
            } ?: return

        val pumps = AlertStore.pumps(context)
        if (pumps.isEmpty()) return
        for (r in results) {
            val d = r.scanRecord?.getManufacturerSpecificData(0xFFFF) ?: continue
            // state, seq, type, arg, tag[4]; the alert bit says one is there.
            if (d.size < 8 || (d[0].toInt() and 0x04) == 0) continue
            val seq = d[1].toInt() and 0xFF
            val type = d[2].toInt() and 0xFF
            val arg = d[3].toInt() and 0xFF
            val tag = d.copyOfRange(4, 8)
            // The phone's address for the pump first, then any pump whose key fits.
            val byMac = pumps.filter { it.mac.equals(r.device.address, ignoreCase = true) }
            val pump = (byMac + pumps).firstOrNull { AlertNotifier.tagOk(it, seq, type, arg, tag) }
                ?: continue
            AlertNotifier.handle(context, pump, seq, type, arg, tag)
        }
    }
}
