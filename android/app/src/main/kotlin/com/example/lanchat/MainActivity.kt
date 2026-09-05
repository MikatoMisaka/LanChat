package com.example.lanchat

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.google.mlkit.common.MlKit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val channelName = "lanchat/multicast"
    private val identityStorageChannelName = "lanchat/identity_storage"
    private val localNotificationChannelName = "lanchat/local_notifications"
    private val localNotificationChannelId = "lanchat_messages"
    private val identityKeyAlias = "lanchat.identity.storage"
    private val identityPreferencesName = "lanchat.identity.storage"
    private val identityStorageExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val identityStorageRequests = mutableMapOf<Long, MethodChannel.Result>()
    private var nextIdentityStorageRequestId = 0L
    private var nextLocalNotificationId = 1
    private var identityStorageClosing = false
    private var lock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureLocalNotificationChannel()
    }

    private fun ensureLocalNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    localNotificationChannelId,
                    "LanChat 消息",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "LanChat 新消息提醒"
                }
            )
        }
    }

    private fun requestLocalNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    private fun showLocalNotification(title: String, body: String) {
        ensureLocalNotificationChannel()
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val pendingIntent = PendingIntent.getActivity(this, 0, intent, pendingFlags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, localNotificationChannelId)
        } else {
            Notification.Builder(this)
        }
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(Notification.PRIORITY_HIGH)
        getSystemService(NotificationManager::class.java).notify(
            nextLocalNotificationId++,
            builder.build()
        )
    }

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, localNotificationChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        ensureLocalNotificationChannel()
                        requestLocalNotificationPermission()
                        result.success(true)
                    }
                    "show" -> {
                        val title = call.argument<String>("title")
                        val body = call.argument<String>("body")
                        if (title.isNullOrBlank() || body.isNullOrBlank()) {
                            result.error(
                                "NOTIFICATION",
                                "Notification title and body are required.",
                                null
                            )
                        } else {
                            showLocalNotification(title, body)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
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
                            stopService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, identityStorageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read", "write", "delete" -> enqueueIdentityStorage(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private sealed class IdentityStorageResponse {
        data class Success(val value: Any?) : IdentityStorageResponse()
        data class Error(val code: String, val message: String?) : IdentityStorageResponse()
    }

    private class IdentityKeyUnavailableException(message: String, cause: Throwable? = null) :
        Exception(message, cause)

    private fun enqueueIdentityStorage(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        if (identityStorageClosing) {
            result.error("ACTIVITY_CLOSING", "Identity storage activity is closing.", null)
            return
        }
        val requestId = ++nextIdentityStorageRequestId
        identityStorageRequests[requestId] = result
        try {
            identityStorageExecutor.execute {
                val response = handleIdentityStorage(call)
                mainHandler.post { completeIdentityStorageRequest(requestId, response) }
            }
        } catch (e: RejectedExecutionException) {
            completeIdentityStorageRequest(
                requestId,
                IdentityStorageResponse.Error("ACTIVITY_CLOSING", "Identity storage activity is closing.")
            )
        }
    }

    private fun completeIdentityStorageRequest(
        requestId: Long,
        response: IdentityStorageResponse
    ) {
        val result = identityStorageRequests.remove(requestId) ?: return
        when (response) {
            is IdentityStorageResponse.Success -> result.success(response.value)
            is IdentityStorageResponse.Error -> result.error(response.code, response.message, null)
        }
    }

    private fun handleIdentityStorage(call: io.flutter.plugin.common.MethodCall): IdentityStorageResponse {
        return try {
            val key = call.argument<String>("key")
                ?: throw IllegalArgumentException("Missing storage key")
            when (call.method) {
                "read" -> IdentityStorageResponse.Success(
                    identityPreferences().getString(key, null)?.let(::decrypt)
                )
                "write" -> {
                    val value = call.argument<String>("value")
                        ?: throw IllegalArgumentException("Missing storage value")
                    if (!identityPreferences().edit().putString(key, encrypt(value)).commit()) {
                        throw IllegalStateException("Unable to persist secure identity value")
                    }
                    IdentityStorageResponse.Success(null)
                }
                "delete" -> {
                    if (!identityPreferences().edit().remove(key).commit()) {
                        throw IllegalStateException("Unable to delete secure identity value")
                    }
                    IdentityStorageResponse.Success(null)
                }
                else -> IdentityStorageResponse.Error("IDENTITY_STORAGE", "Unsupported storage method")
            }
        } catch (e: IdentityKeyUnavailableException) {
            IdentityStorageResponse.Error(
                "IDENTITY_KEY_UNRECOVERABLE",
                "${e.message} Remove secure identity storage before creating a new identity."
            )
        } catch (e: Exception) {
            IdentityStorageResponse.Error("IDENTITY_STORAGE", e.message)
        }
    }

    private fun identityPreferences(): SharedPreferences =
        getSharedPreferences(identityPreferencesName, Context.MODE_PRIVATE)

    private fun identityKey(createIfMissing: Boolean): SecretKey {
        try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (keyStore.getKey(identityKeyAlias, null) as? SecretKey)?.let { return it }
            if (!createIfMissing) {
                throw IdentityKeyUnavailableException("The device-bound identity key is unavailable.")
            }
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                init(
                    KeyGenParameterSpec.Builder(
                        identityKeyAlias,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build()
                )
                generateKey()
            }
        } catch (e: IdentityKeyUnavailableException) {
            throw e
        } catch (e: Exception) {
            throw IdentityKeyUnavailableException(
                "The device-bound identity key is unavailable.",
                e
            )
        }
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, identityKey(createIfMissing = true))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String {
        try {
            val parts = value.split(":", limit = 2)
            if (parts.size != 2) throw IllegalStateException("Stored identity value is malformed")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                identityKey(createIfMissing = false),
                GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP))
            )
            return cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)).toString(Charsets.UTF_8)
        } catch (e: IdentityKeyUnavailableException) {
            throw e
        } catch (e: Exception) {
            throw IdentityKeyUnavailableException(
                "Stored identity material cannot be decrypted on this device.",
                e
            )
        }
    }

    override fun onDestroy() {
        identityStorageClosing = true
        for (result in identityStorageRequests.values) {
            result.error("ACTIVITY_CLOSING", "Identity storage activity is closing.", null)
        }
        identityStorageRequests.clear()
        identityStorageExecutor.shutdownNow()
        lock?.release()
        lock = null
        super.onDestroy()
    }
}
