package com.example.cc_remote

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "cc_remote/camera_permission"
    private val cameraRequestCode = 4101
    private val cameraDenialCountKey = "camera_denial_count"
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(cameraPermissionState())
                    "request" -> requestCameraPermission(result)
                    "shouldRequestOnLaunch" ->
                        result.success(
                            getPreferences(MODE_PRIVATE).getInt(cameraDenialCountKey, 0) == 0,
                        )
                    "openSettings" -> result.success(openApplicationSettings())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cc_remote/delivery_files")
            .setMethodCallHandler { call, result ->
                if (call.method != "open" && call.method != "share") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val path = call.argument<String>("path") ?: error("missing_path")
                    val file = File(path).canonicalFile
                    val allowed = File(cacheDir, "deliveries").canonicalPath + File.separator
                    require(file.path.startsWith(allowed) && file.isFile) { "invalid_file" }
                    val uri = FileProvider.getUriForFile(this, "$packageName.deliveries", file)
                    val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                    val sharing = call.method == "share"
                    val intent = Intent(if (sharing) Intent.ACTION_SEND else Intent.ACTION_VIEW).apply {
                        if (sharing) {
                            type = mime
                            putExtra(Intent.EXTRA_STREAM, uri)
                        } else {
                            setDataAndType(uri, mime)
                        }
                        clipData = ClipData.newUri(contentResolver, file.name, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    if (intent.resolveActivity(packageManager) == null) {
                        result.error("no_app", "No app can open this file", null)
                    } else {
                        startActivity(Intent.createChooser(intent, if (sharing) "分享文件" else "选择打开方式"))
                        result.success(null)
                    }
                } catch (_: ActivityNotFoundException) {
                    result.error("no_app", "No app can open this file", null)
                } catch (_: Exception) {
                    result.error("file_action_failed", "Could not open file", null)
                }
            }
    }

    private fun cameraPermissionState(): String {
        return if (
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            "granted"
        } else if (
            getPreferences(MODE_PRIVATE).getInt(cameraDenialCountKey, 0) >= 2 &&
                !ActivityCompat.shouldShowRequestPermissionRationale(
                    this,
                    Manifest.permission.CAMERA,
                )
        ) {
            "permanentlyDenied"
        } else {
            "denied"
        }
    }

    private fun requestCameraPermission(result: MethodChannel.Result) {
        val currentState = cameraPermissionState()
        if (currentState == "granted" || currentState == "permanentlyDenied") {
            result.success(currentState)
            return
        }
        if (permissionResult != null) {
            result.success(cameraPermissionState())
            return
        }
        permissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.CAMERA),
            cameraRequestCode,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != cameraRequestCode) return
        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        val preferences = getPreferences(MODE_PRIVATE)
        preferences
            .edit()
            .putInt(
                cameraDenialCountKey,
                if (granted) 0 else preferences.getInt(cameraDenialCountKey, 0) + 1,
            )
            .apply()
        permissionResult?.success(cameraPermissionState())
        permissionResult = null
    }

    private fun openApplicationSettings(): Boolean {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null),
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return true
    }
}

class DeliveryFileProvider : FileProvider()
