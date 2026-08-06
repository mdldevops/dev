package com.example.piso_stream

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors

class ChargingMonitorService : Service() {
    companion object {
        private const val logTag = "PisoStreamChargeSvc"
        private const val channelId = "charging_monitor"
        private const val notificationId = 4301
        private const val intervalMs = 60_000L

        fun start(context: Context) {
            val intent = Intent(context.applicationContext, ChargingMonitorService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.applicationContext.startForegroundService(intent)
                } else {
                    context.applicationContext.startService(intent)
                }
                Log.d(logTag, "Charging foreground service start requested")
            } catch (error: Exception) {
                Log.w(logTag, "Unable to start charging foreground service", error)
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var running = false

    private val monitorRunnable = object : Runnable {
        override fun run() {
            executor.execute {
                try {
                    Log.d(logTag, "Charging foreground monitor tick")
                    val result = ChargingMonitorReceiver.evaluateNow(applicationContext)
                    Log.d(logTag, "Charging foreground monitor result=$result")
                } catch (error: Exception) {
                    Log.w(logTag, "Charging foreground monitor failed", error)
                }
            }
            handler.postDelayed(this, intervalMs)
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(notificationId, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!running) {
            running = true
            Log.d(logTag, "Charging foreground service running")
            handler.post(monitorRunnable)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(monitorRunnable)
        executor.shutdownNow()
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            channelId,
            "Charging Monitor",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps tablet charging control active."
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(channel)
    }

    private fun buildNotification() =
        NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_lock_idle_charging)
            .setContentTitle("Charging control active")
            .setContentText("Monitoring battery every 60 seconds.")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
}
