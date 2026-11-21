package com.tanklink.tanklink

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * A Bluetooth scan Android runs for us (a PendingIntent scan), so a pump's
 * alert reaches [AlertScanReceiver] with the app closed. The filter only
 * matches the pump's advertisement with the alert bit set, so a pump with no
 * alert (and a tank sensor) never wakes the app.
 */
object AlertScanner {
    private fun pending(c: Context): PendingIntent =
        PendingIntent.getBroadcast(
            c,
            1,
            Intent(c, AlertScanReceiver::class.java),
            // Mutable on purpose: Android adds the scan results to the intent.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    fun supported() = Build.VERSION.SDK_INT >= 31

    fun hasScanPermission(c: Context) =
        Build.VERSION.SDK_INT < 31 ||
            c.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED

    /** Start or stop the scan to match the settings. Safe to call any time. */
    fun register(c: Context) {
        if (!supported()) return
        val adapter = (c.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        val scanner = adapter?.bluetoothLeScanner
        val want = AlertStore.enabled(c) && AlertStore.pumps(c).isNotEmpty() && hasScanPermission(c)
        try {
            if (scanner == null) return
            if (!want) {
                scanner.stopScan(pending(c))
                return
            }
            // state byte with the alert bit, then 7 alert bytes we don't care about.
            val data = ByteArray(8).also { it[0] = 0x04 }
            val mask = ByteArray(8).also { it[0] = 0x04 }
            val filter = ScanFilter.Builder().setManufacturerData(0xFFFF, data, mask).build()
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
                .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                .build()
            scanner.startScan(listOf(filter), settings, pending(c))
        } catch (_: SecurityException) {
            // Permission taken away since we checked: nothing to scan with.
        }
    }
}
