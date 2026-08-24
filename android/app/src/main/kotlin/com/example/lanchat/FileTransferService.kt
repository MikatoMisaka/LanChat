package com.example.lanchat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 接收文件期间的常驻前台服务：
 * 通知栏显示"正在接收文件"，持有 PARTIAL_WAKE_LOCK，
 * 防止应用退到后台/熄屏后进程被冻结导致传输中断。
 */
class FileTransferService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            releaseAndStop()
            return START_NOT_STICKY
        }

        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                CHANNEL_ID, "文件传输", NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }

        val builder: Notification.Builder =
            if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
        val notification = builder
            .setContentTitle("LanChat 正在接收文件")
            .setContentText("保持后台运行中，以防传输中断")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()

        startForeground(NOTIF_ID, notification)

        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "lanchat:file_transfer"
            ).apply {
                setReferenceCounted(false)
                // 单次传输兜底上限 30 分钟，防止泄漏
                acquire(30 * 60 * 1000L)
            }
        }
        return START_NOT_STICKY
    }

    private fun releaseAndStop() {
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val ACTION_STOP = "com.example.lanchat.STOP_TRANSFER"
        private const val CHANNEL_ID = "file_transfer"
        private const val NOTIF_ID = 9527
    }
}
