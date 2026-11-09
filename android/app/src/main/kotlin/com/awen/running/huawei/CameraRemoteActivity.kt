package com.awen.running.huawei

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.Camera
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 手表遥控拍照相机页
 *
 * 手表发出 OPEN_CAMERA 时由 [VitaloopWatchManager] 拉起；
 * TAKE_PICTURE 触发拍照并保存到 相册/HealthSync/，CLOSE_CAMERA 关闭页面。
 */
class CameraRemoteActivity : ComponentActivity(), SurfaceHolder.Callback {

    companion object {
        private const val TAG = "CameraRemote"
        const val ACTION_TAKE_PICTURE = "me.awen.vitaloop.CAMERA_REMOTE_TAKE"
        const val ACTION_CLOSE = "me.awen.vitaloop.CAMERA_REMOTE_CLOSE"
    }

    private var camera: Camera? = null
    private var surfaceHolder: SurfaceHolder? = null
    private var takingPicture = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_TAKE_PICTURE -> takePicture()
                ACTION_CLOSE -> finish()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val surface = SurfaceView(this)
        setContentView(surface)
        surface.holder.addCallback(this)

        val filter = IntentFilter().apply {
            addAction(ACTION_TAKE_PICTURE)
            addAction(ACTION_CLOSE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
    }

    override fun onResume() {
        super.onResume()
        openCamera()
    }

    override fun onPause() {
        super.onPause()
        releaseCamera()
    }

    override fun onDestroy() {
        super.onDestroy()
        runCatching { unregisterReceiver(receiver) }
        releaseCamera()
    }

    private fun openCamera() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Toast.makeText(this, "无相机权限，无法使用遥控拍照", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        runCatching {
            camera = Camera.open()
            surfaceHolder?.let { camera?.setPreviewDisplay(it) }
            camera?.startPreview()
        }.onFailure {
            Log.e(TAG, "打开相机失败", it)
            Toast.makeText(this, "打开相机失败", Toast.LENGTH_SHORT).show()
        }
    }

    private fun releaseCamera() {
        runCatching { camera?.stopPreview() }
        camera?.release()
        camera = null
    }

    private fun takePicture() {
        if (takingPicture) return
        takingPicture = true
        camera?.takePicture(null, null) { data, _ ->
            saveJpeg(data)
            takingPicture = false
        } ?: run { takingPicture = false }
    }

    private fun saveJpeg(data: ByteArray) {
        try {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                "HealthSync"
            )
            if (!dir.exists()) dir.mkdirs()
            val name = "watch_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())}.jpg"
            val file = File(dir, name)
            FileOutputStream(file).use { it.write(data) }
            MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), null, null)
            Log.i(TAG, "照片已保存: ${file.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "保存照片失败", e)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceHolder = holder
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        runCatching { camera?.setPreviewDisplay(holder) }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        releaseCamera()
    }
}
