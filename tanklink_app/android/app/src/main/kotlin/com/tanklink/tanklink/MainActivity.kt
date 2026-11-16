package com.tanklink.tanklink

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val CHANNEL = "com.tanklink/install"
    }
}