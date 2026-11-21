package com.tanklink.tanklink

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** After a restart or an app update the scan is gone: start it again. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AlertScanner.register(context)
    }
}
