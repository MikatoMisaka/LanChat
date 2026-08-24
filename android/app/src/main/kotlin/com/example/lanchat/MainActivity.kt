package com.example.lanchat

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import com.google.mlkit.common.MlKit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "lanchat/multicast"
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // 部分设备/安装方式下 MlKitInitProvider 未在进程启动时完成初始化，
        // 扫码时 BarcodeScanning.getClient() 会抛 NullPointerException
        // （Dart 侧表现为 genericError + "Attempt to invoke virtual method
        // 'java.lang.Object.getClass()' on a null object reference"）。
        // 在插件注册前强制初始化 ML Kit（幂等，已初始化则无副作用）。
        try {
            MlKit.initialize(applicationContext)
        } catch (_: Exception) {
        }
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            if (lock == null) {
                                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                lock = wifi.createMulticastLock("lanchat").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MULTICAST", e.message, null)
                        }
                    }
                    "release" -> {
                        try {
                            lock?.release()
                            lock = null
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MULTICAST", e.message, null)
                        }
                    }
                    "openSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.parse("package:$packageName"))
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS", e.message, null)
                        }
                    }
                    "startTransferService" -> {
                        try {
                            val intent = Intent(this, FileTransferService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE", e.message, null)
                        }
                    }
                    "stopTransferService" -> {
                        try {
                            val intent = Intent(this, FileTransferService::class.java)
                            intent.action = FileTransferService.ACTION_STOP
                            if (Build.VERSION.SDK_INT >= 26) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        lock?.release()
        lock = null
        super.onDestroy()
    }
}
