package com.example.cc_remote

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
