package com.example.piso_stream

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import android.util.Log
import java.io.File
import java.util.LinkedHashSet

class KioskSessionAlarmReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_WARN_ONE_MINUTE = "com.example.piso_stream.SESSION_WARN_ONE_MINUTE"
        const val ACTION_WARN_TWENTY_SECONDS =
            "com.example.piso_stream.SESSION_WARN_TWENTY_SECONDS"
        const val ACTION_SESSION_EXPIRED = "com.example.piso_stream.SESSION_EXPIRED"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val SESSION_ALERT_CHANNEL_ID = "session_alerts"
        const val SESSION_ALERT_NOTIFICATION_ID = 3101
        const val SESSION_EXPIRED_CHANNEL_ID = "session_expired_alerts"
        const val SESSION_EXPIRED_NOTIFICATION_ID = 3106
        private const val FLUTTER_PREFS_NAME = "FlutterSharedPreferences"
        private const val POLICY_PREFS_NAME = "kiosk_policy_prefs"
        private const val LAST_LAUNCHED_APP_KEY = "last_launched_app_package"
    }

    private val logTag = "PisoStreamKiosk"

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_WARN_ONE_MINUTE -> {
                showWarningNotification(
                    context = context,
                    title = intent.getStringExtra(EXTRA_TITLE) ?: "Session Time Warning",
                    body = intent.getStringExtra(EXTRA_BODY)
                        ?: "Your session is about to expire."
                )
            }

            ACTION_WARN_TWENTY_SECONDS -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "20 seconds remaining"
                val body = intent.getStringExtra(EXTRA_BODY)
                    ?: "Returning to launcher. Insert coins now if you want to continue your session."
                showWarningNotification(
                    context = context,
                    title = title,
                    body = body
                )
                closeLastLaunchedApp(context)
                returnLauncherToFront(context)
            }

            ACTION_SESSION_EXPIRED -> {
                handleSessionExpired(context)
            }
        }
    }

    private fun handleSessionExpired(context: Context) {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
        val currentCustomer = prefs.getString(flutterKey("current_customer_username"), null)
            ?.trim()
            .orEmpty()
        val currentRole = prefs.getString(flutterKey("current_customer_role"), null)
            ?.trim()
            ?.lowercase()
            .orEmpty()

        val editor = prefs.edit()
            .putBoolean(flutterKey("session_expired_pending"), true)
            .remove(flutterKey("session_expires_at"))

        if (currentCustomer.isNotEmpty() && currentRole != "admin") {
            val idleDeadline = System.currentTimeMillis() + 60_000L
            editor.putLong(flutterKey("customer_idle_deadline"), idleDeadline)
            editor.remove(flutterKey("current_customer_username"))
            editor.remove(flutterKey("current_customer_role"))
        } else {
            editor.remove(flutterKey("customer_idle_deadline"))
        }
        editor.apply()

        closeLastLaunchedApp(context)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra(MainActivity.EXTRA_SESSION_EXPIRED, true)
            putExtra(MainActivity.EXTRA_FORCE_SCREEN_ON, true)
        }

        try {
            context.startActivity(launchIntent)
        } catch (_: Exception) {
        }

        showExpiredNotification(context)
        NotificationManagerCompat.from(context).cancel(SESSION_ALERT_NOTIFICATION_ID)

    }

    private fun showExpiredNotification(context: Context) {
        Log.d("KioskSessionAlarmReceiver", "Preparing expired notification")
        val notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
        Log.d("KioskSessionAlarmReceiver", "areNotificationsEnabled=$notificationsEnabled")
        val channelId = createExpiredNotificationChannel(context)
        try {
            val manager = context.getSystemService(NotificationManager::class.java)
            Log.d("KioskSessionAlarmReceiver", "expired channel exists=${manager?.getNotificationChannel(channelId) != null}")
        } catch (_: Exception) {
        }
        val title = "Session expired"
        val body = "Your session has ended and you have been logged out."
        val fullScreenIntent = buildLauncherPendingIntent(context)
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setContentIntent(fullScreenIntent)
            .setFullScreenIntent(fullScreenIntent, true)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setSound(resolveNotificationSoundUri(null))
            builder.setVibrate(longArrayOf(0, 300, 200, 300))
        }

        try {
            NotificationManagerCompat.from(context)
                .notify(SESSION_EXPIRED_NOTIFICATION_ID, builder.build())
            Log.d("KioskSessionAlarmReceiver", "expired notification posted")
        } catch (_: SecurityException) {
            Log.w("KioskSessionAlarmReceiver", "SecurityException posting expired notification")
        }
    }

    private fun createExpiredNotificationChannel(context: Context): String {
        val channelId = SESSION_EXPIRED_CHANNEL_ID
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return channelId
        }

        val manager = context.getSystemService(NotificationManager::class.java) ?: return channelId
        val existingChannel = manager.getNotificationChannel(channelId)
        val soundUri = resolveNotificationSoundUri(null)
        if (existingChannel != null) {
            if (existingChannel.importance != NotificationManager.IMPORTANCE_HIGH ||
                existingChannel.shouldVibrate() != true ||
                existingChannel.sound != soundUri
            ) {
                manager.deleteNotificationChannel(channelId)
            } else {
                return channelId
            }
        }

        val channel = NotificationChannel(
            channelId,
            "Session expired alerts",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Notifications for session expiry and logout events."
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 300, 200, 300)
            setSound(
                soundUri,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        }

        manager.createNotificationChannel(channel)
        return channelId
    }

    private fun showWarningNotification(context: Context, title: String, body: String) {
        Log.d("KioskSessionAlarmReceiver", "Preparing warning notification: $title")
        val prefs = context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(flutterKey("low_time_alerts_enabled"), true)
        if (!enabled) {
            return
        }

        val soundPath = prefs.getString(flutterKey("low_time_alerts_sound_path"), null)
            ?.trim()
            .orEmpty()
        val vibrationEnabled = prefs.getBoolean(
            flutterKey("low_time_alerts_vibration_enabled"),
            true
        )

        val fullScreenIntent = buildLauncherPendingIntent(context)
        val channelId = createNotificationChannel(context, soundPath, vibrationEnabled)
        try {
            val notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
            Log.d("KioskSessionAlarmReceiver", "areNotificationsEnabled=$notificationsEnabled")
            val manager = context.getSystemService(NotificationManager::class.java)
            Log.d("KioskSessionAlarmReceiver", "warning channel exists=${manager?.getNotificationChannel(channelId) != null}")
        } catch (_: Exception) {
        }
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setContentIntent(fullScreenIntent)
            .setFullScreenIntent(fullScreenIntent, true)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setSound(resolveNotificationSoundUri(soundPath))
            if (vibrationEnabled) {
                builder.setVibrate(longArrayOf(0, 300, 200, 300))
            } else {
                builder.setVibrate(longArrayOf(0L))
            }
        }

        try {
            NotificationManagerCompat.from(context)
                .notify(SESSION_ALERT_NOTIFICATION_ID, builder.build())
            Log.d("KioskSessionAlarmReceiver", "warning notification posted")
        } catch (_: SecurityException) {
            Log.w("KioskSessionAlarmReceiver", "SecurityException posting warning notification")
        } catch (ex: Exception) {
            Log.w("KioskSessionAlarmReceiver", "Exception posting warning notification: ${ex.message}")
        }

    }

    private fun returnLauncherToFront(context: Context) {
        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val moved = activityManager?.appTasks?.any { appTask ->
            val baseIntent = appTask.taskInfo?.baseIntent
            if (baseIntent?.component?.className == MainActivity::class.java.name) {
                try {
                    appTask.moveToFront()
                    true
                } catch (_: Exception) {
                    false
                }
            } else {
                false
            }
        } == true

        if (moved) {
            Log.d("KioskSessionAlarmReceiver", "moved existing launcher task to front")
        }

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra(MainActivity.EXTRA_ENFORCE_CLOSE_RETURN, true)
            putExtra(MainActivity.EXTRA_FORCE_SCREEN_ON, true)
        }

        try {
            context.startActivity(launchIntent)
            Log.d("KioskSessionAlarmReceiver", "launched MainActivity for 20-second warning")
        } catch (ex: Exception) {
            Log.w(
                "KioskSessionAlarmReceiver",
                "failed to launch MainActivity for 20-second warning: ${ex.message}"
            )
        }
    }

    private fun closeLastLaunchedApp(context: Context) {
        val prefs = context.getSharedPreferences(POLICY_PREFS_NAME, Context.MODE_PRIVATE)
        val fallbackPackage = prefs.getString(LAST_LAUNCHED_APP_KEY, null)
            ?.trim()
            .orEmpty()
        val targetPackages = resolvePackagesToClose(context, fallbackPackage)

        if (targetPackages.isEmpty()) {
            val debugSummary =
                "pkgs=<none> fallback=${if (fallbackPackage.isEmpty()) "<none>" else fallbackPackage}"
            context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(flutterKey("native_close_debug"), debugSummary)
                .apply()
            Log.d(logTag, "closeLastLaunchedApp $debugSummary")
            return
        }

        val revokedFromLockTask = revokePackageFromLockTaskAllowlist(context)
        var closeApplied = false
        val closeResults = targetPackages.map { targetPackage ->
            val suspendedByPolicy = temporarilySuspendAndRestorePackage(context, targetPackage)
            val hiddenByPolicy = temporarilyHideAndRestorePackage(context, targetPackage)
            val forceStopped = runShellCommand("am force-stop $targetPackage")
            closeApplied = closeApplied || suspendedByPolicy || hiddenByPolicy || forceStopped
            "$targetPackage[suspend=$suspendedByPolicy hide=$hiddenByPolicy force=$forceStopped]"
        }
        val debugSummary =
            "pkgs=${closeResults.joinToString(",")} revoke=$revokedFromLockTask"

        context.getSharedPreferences(FLUTTER_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(flutterKey("native_close_debug"), debugSummary)
            .apply()

        Log.d("KioskSessionAlarmReceiver", "closeLastLaunchedApp $debugSummary")
        Log.d(logTag, "closeLastLaunchedApp $debugSummary")

        if (closeApplied) {
            prefs.edit().remove(LAST_LAUNCHED_APP_KEY).apply()
        } else {
            Log.d(logTag, "Retaining fallback package for retry: $fallbackPackage")
        }
    }

    private fun resolvePackagesToClose(
        context: Context,
        fallbackPackage: String
    ): List<String> {
        val targetPackages = LinkedHashSet<String>()
        val topPackage = resolveCurrentOpenAppPackage(context, "")

        if (
            topPackage.isNotBlank() &&
            topPackage != context.packageName &&
            topPackage != "com.android.settings"
        ) {
            targetPackages.add(topPackage)
        }

        if (
            fallbackPackage.isNotBlank() &&
            fallbackPackage != context.packageName &&
            fallbackPackage != "com.android.settings"
        ) {
            targetPackages.add(fallbackPackage)
        }

        return targetPackages.toList()
    }

    private fun revokePackageFromLockTaskAllowlist(context: Context): Boolean {
        val devicePolicyManager = context.getSystemService(DevicePolicyManager::class.java)
            ?: return false
        val adminComponent = ComponentName(context, KioskDeviceAdminReceiver::class.java)

        if (!devicePolicyManager.isDeviceOwnerApp(context.packageName)) {
            return false
        }

        return try {
            devicePolicyManager.setLockTaskPackages(
                adminComponent,
                arrayOf(context.packageName, "com.android.settings")
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                devicePolicyManager.setLockTaskFeatures(
                    adminComponent,
                    DevicePolicyManager.LOCK_TASK_FEATURE_NONE
                )
            }
            Log.d(
                logTag,
                "Revoked other packages from lock-task allowlist"
            )
            true
        } catch (error: Exception) {
            Log.w(
                logTag,
                "Failed to revoke lock-task allowlist: ${error.message}"
            )
            false
        }
    }

    private fun resolveCurrentOpenAppPackage(
        context: Context,
        fallbackPackage: String
    ): String {
        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager

        val topPackage = try {
            @Suppress("DEPRECATION")
            activityManager
                ?.getRunningTasks(5)
                ?.asSequence()
                ?.mapNotNull { taskInfo -> taskInfo.topActivity?.packageName }
                ?.firstOrNull { packageName ->
                    packageName.isNotBlank() && packageName != context.packageName
                }
                .orEmpty()
        } catch (_: Exception) {
            ""
        }

        if (topPackage.isNotEmpty()) {
            Log.d(
                logTag,
                "Resolved current open app package from running tasks: $topPackage"
            )
            return topPackage
        }

        if (fallbackPackage.isNotEmpty()) {
            Log.d(
                logTag,
                "Falling back to last launched app package: $fallbackPackage"
            )
        }

        return fallbackPackage
    }

    private fun temporarilyHideAndRestorePackage(
        context: Context,
        targetPackage: String
    ): Boolean {
        val devicePolicyManager = context.getSystemService(DevicePolicyManager::class.java)
            ?: return false
        val adminComponent = ComponentName(context, KioskDeviceAdminReceiver::class.java)

        if (!devicePolicyManager.isDeviceOwnerApp(context.packageName)) {
            return false
        }

        return try {
            val hidden = devicePolicyManager.setApplicationHidden(adminComponent, targetPackage, true)
            val restored = devicePolicyManager.setApplicationHidden(adminComponent, targetPackage, false)
            Log.d(
                logTag,
                "temporarilyHideAndRestorePackage package=$targetPackage hidden=$hidden restored=$restored"
            )
            hidden || restored
        } catch (error: Exception) {
            Log.w(
                logTag,
                "Failed to hide/unhide package $targetPackage: ${error.message}"
            )
            false
        }
    }

    private fun temporarilySuspendAndRestorePackage(
        context: Context,
        targetPackage: String
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return false
        }

        val devicePolicyManager = context.getSystemService(DevicePolicyManager::class.java)
            ?: return false
        val adminComponent = ComponentName(context, KioskDeviceAdminReceiver::class.java)

        if (!devicePolicyManager.isDeviceOwnerApp(context.packageName)) {
            return false
        }

        return try {
            devicePolicyManager.setPackagesSuspended(
                adminComponent,
                arrayOf(targetPackage),
                true
            )

            Handler(Looper.getMainLooper()).postDelayed(
                {
                    try {
                        devicePolicyManager.setPackagesSuspended(
                            adminComponent,
                            arrayOf(targetPackage),
                            false
                        )
                        Log.d(
                            logTag,
                            "Restored suspended package $targetPackage"
                        )
                    } catch (error: Exception) {
                        Log.w(
                            logTag,
                            "Failed to restore suspended package $targetPackage: ${error.message}"
                        )
                    }
                },
                1500L
            )

            Log.d(
                logTag,
                "Suspended package $targetPackage"
            )
            true
        } catch (error: Exception) {
            Log.w(
                logTag,
                "Failed to suspend package $targetPackage: ${error.message}"
            )
            false
        }
    }

    private fun runShellCommand(command: String): Boolean {
        return try {
            val process = ProcessBuilder("sh", "-c", command)
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            process.waitFor()
            val exitValue = process.exitValue()
            Log.d(
                logTag,
                "Shell command '$command' output: '$output', exitValue=$exitValue"
            )
            exitValue == 0
        } catch (error: Exception) {
            Log.w(
                logTag,
                "Error running shell command '$command': ${error.message}"
            )
            false
        }
    }

    private fun buildLauncherPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra(MainActivity.EXTRA_FORCE_SCREEN_ON, true)
        }

        return PendingIntent.getActivity(
            context,
            SESSION_ALERT_NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun createNotificationChannel(
        context: Context,
        soundPath: String,
        vibrationEnabled: Boolean
    ): String {
        val channelId = if (soundPath.isBlank()) {
            SESSION_ALERT_CHANNEL_ID
        } else {
            "${SESSION_ALERT_CHANNEL_ID}_${soundPath.hashCode()}_${if (vibrationEnabled) "v" else "s"}"
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return channelId
        }

        val manager = context.getSystemService(NotificationManager::class.java) ?: return channelId
        val soundUri = resolveNotificationSoundUri(soundPath)
        val existingChannel = manager.getNotificationChannel(channelId)
        if (existingChannel != null) {
            if (existingChannel.importance != NotificationManager.IMPORTANCE_HIGH ||
                existingChannel.shouldVibrate() != vibrationEnabled ||
                existingChannel.sound != soundUri
            ) {
                manager.deleteNotificationChannel(channelId)
            } else {
                return channelId
            }
        }

        val channel = NotificationChannel(
            channelId,
            "Session Alerts",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            enableVibration(vibrationEnabled)
            if (vibrationEnabled) {
                vibrationPattern = longArrayOf(0, 300, 200, 300)
            }
            setSound(
                soundUri,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        }

        manager.createNotificationChannel(channel)
        return channelId
    }

    private fun resolveNotificationSoundUri(soundPath: String?): Uri {
        val normalizedPath = soundPath?.trim().orEmpty()
        if (normalizedPath.isNotBlank()) {
            val file = File(normalizedPath)
            if (file.exists()) {
                return Uri.fromFile(file)
            }
        }

        return RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
    }

    private fun flutterKey(key: String): String = "flutter.$key"
}
