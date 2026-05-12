package com.example.piso_stream

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Bundle
import android.os.Build
import android.os.Looper
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.BatteryManager
import android.provider.Settings
import android.media.RingtoneManager
import android.os.UserManager
import android.app.ActivityManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.util.LinkedHashSet
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.TimeUnit
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val logTag = "PisoStreamKiosk"
    private val channelName = "com.example.piso_stream/installed_apps"
    private val sessionAlertChannelId = "session_alerts"
    private val sessionAlertNotificationId = 3101
    private val policyPrefsName = "kiosk_policy_prefs"
    private val allowAppUpdatesKey = "allow_app_updates"
    private val audioFadeDurationMs = 500L
    private val audioFadeSteps = 10
    private var isAdminWifiSessionActive = false
    private var mediaPlayer: MediaPlayer? = null
    private var effectMediaPlayer: MediaPlayer? = null
    private val audioFadeHandler = Handler(Looper.getMainLooper())
    private var activeAudioFade: Runnable? = null
    private var targetAudioVolume = 0.5f
    private val adminComponent by lazy {
        ComponentName(this, KioskDeviceAdminReceiver::class.java)
    }
    private val devicePolicyManager by lazy {
        getSystemService(DevicePolicyManager::class.java)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
        applyImmersiveMode()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledApps" -> result.success(getInstalledApps())
                    "enterKioskMode" -> {
                        enterKioskMode()
                        result.success(null)
                    }
                    "exitKioskMode" -> {
                        exitKioskMode()
                        result.success(null)
                    }
                    "isDeviceOwner" -> {
                        result.success(isDeviceOwnerApp())
                    }
                    "restartApp" -> {
                        restartApp()
                        result.success(null)
                    }
                    "setAppUpdatesAllowed" -> {
                        val allowed = call.argument<Boolean>("allowed") ?: true
                        setAppUpdatesAllowed(allowed)
                        result.success(null)
                    }
                    "rebootDevice" -> {
                        if (rebootDevice()) {
                            result.success(null)
                        } else {
                            result.error("REBOOT_UNAVAILABLE", "Device reboot requires an active device owner.", null)
                        }
                    }
                    "getSystemStatus" -> {
                        result.success(getSystemStatus())
                    }
                    "playAudio" -> {
                        val audioPath = call.argument<String>("audioPath")
                        val loop = call.argument<Boolean>("loop") ?: true
                        val volume = call.argument<Double>("volume")?.toFloat() ?: 0.5f

                        if (audioPath.isNullOrBlank()) {
                            result.error("INVALID_AUDIO_PATH", "Audio path is required.", null)
                        } else if (playAudio(audioPath, loop, volume)) {
                            result.success(null)
                        } else {
                            result.error("AUDIO_PLAYBACK_FAILED", "Unable to play the selected audio file.", null)
                        }
                    }
                    "playEffectAudio" -> {
                        val audioPath = call.argument<String>("audioPath")
                        val volume = call.argument<Double>("volume")?.toFloat() ?: 0.5f

                        if (audioPath.isNullOrBlank()) {
                            result.error("INVALID_AUDIO_PATH", "Audio path is required.", null)
                        } else if (playEffectAudio(audioPath, volume)) {
                            result.success(null)
                        } else {
                            result.error("AUDIO_EFFECT_FAILED", "Unable to play the selected coin/time audio file.", null)
                        }
                    }
                    "getAudioDurationMs" -> {
                        val audioPath = call.argument<String>("audioPath")
                        if (audioPath.isNullOrBlank()) {
                            result.error("INVALID_AUDIO_PATH", "Audio path is required.", null)
                        } else {
                            result.success(getAudioDurationMs(audioPath))
                        }
                    }
                    "stopAudio" -> {
                        stopAudio()
                        result.success(null)
                    }
                    "setAudioVolume" -> {
                        val volume = call.argument<Double>("volume")?.toFloat() ?: 0.5f
                        setAudioVolume(volume)
                        result.success(null)
                    }
                    "openWifiSettings" -> {
                        if (openWifiSettings()) {
                            result.success(null)
                        } else {
                            result.error("WIFI_SETTINGS_UNAVAILABLE", "Unable to open Wi-Fi settings.", null)
                        }
                    }
                    "resetWhitelistedApps" -> {
                        val packageNames = call.argument<List<String>>("packageNames").orEmpty()
                        val failures = resetWhitelistedApps(packageNames)

                        if (failures.isEmpty()) {
                            result.success(null)
                        } else {
                            result.error(
                                "RESET_FAILED",
                                "Unable to reset: ${failures.joinToString(", ")}",
                                failures
                            )
                        }
                    }
                    "launchApp" -> {
                        val packageName = call.argument<String>("packageName")

                        if (packageName.isNullOrBlank()) {
                            result.error("INVALID_PACKAGE", "Package name is required.", null)
                            return@setMethodCallHandler
                        }

                        if (launchApp(packageName)) {
                            result.success(null)
                        } else {
                            result.error("APP_NOT_FOUND", "App is not available on this device.", null)
                        }
                    }
                    "showSessionWarningNotification" -> {
                        val title = call.argument<String>("title") ?: "Session Time Warning"
                        val body = call.argument<String>("body") ?: "Your session is about to expire."
                        val soundPath = call.argument<String>("soundPath")
                        val vibrationEnabled = call.argument<Boolean>("vibrationEnabled") ?: true
                        showSessionWarningNotification(title, body, soundPath, vibrationEnabled)
                        result.success(null)
                    }
                    "cancelSessionWarningNotification" -> {
                        cancelSessionWarningNotification()
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermissionIfNeeded()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        applyImmersiveMode()
        if (isAdminWifiSessionActive) {
            isAdminWifiSessionActive = false
            restoreKioskRestrictions()
        } else {
            enterKioskMode()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            applyImmersiveMode()
        }
    }

    override fun onDestroy() {
        stopAudio(immediate = true)
        stopEffectAudio()
        super.onDestroy()
    }

    private fun enterKioskMode() {
        applyImmersiveMode()
        applyHardKioskPolicies()

        if (isCurrentlyInLockTaskMode()) {
            Log.d(logTag, "Lock task already active. Skipping duplicate startLockTask call.")
            return
        }

        try {
            val dpm = devicePolicyManager
            val isPermitted = dpm?.isLockTaskPermitted(packageName) == true

            if (isPermitted || !isDeviceOwnerApp()) {
                startLockTask()
                Log.d(logTag, "startLockTask requested. permitted=$isPermitted owner=${isDeviceOwnerApp()}")
            } else {
                Log.w(logTag, "Lock task not permitted for package: $packageName")
            }
        } catch (_: IllegalArgumentException) {
            Log.w(logTag, "startLockTask failed: IllegalArgumentException")
        } catch (_: IllegalStateException) {
            Log.w(logTag, "startLockTask failed: IllegalStateException")
        }
    }

    private fun exitKioskMode() {
        try {
            stopLockTask()
        } catch (_: IllegalArgumentException) {
        } catch (_: IllegalStateException) {
        }
    }

    private fun isDeviceOwnerApp(): Boolean {
        return devicePolicyManager?.isDeviceOwnerApp(packageName) == true
    }

    private fun isCurrentlyInLockTaskMode(): Boolean {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activityManager?.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
        } else {
            @Suppress("DEPRECATION")
            activityManager?.isInLockTaskMode
        } == true
    }

    private fun applyHardKioskPolicies() {
        if (!isDeviceOwnerApp()) {
            return
        }

        val dpm = devicePolicyManager ?: return

        try {
            setAllowedLockTaskPackages("com.android.settings")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                dpm.setLockTaskFeatures(adminComponent, DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
            }

            dpm.addPersistentPreferredActivity(
                adminComponent,
                IntentFilter(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_HOME)
                    addCategory(Intent.CATEGORY_DEFAULT)
                },
                ComponentName(this, MainActivity::class.java)
            )
            dpm.setStatusBarDisabled(adminComponent, true)
            dpm.setKeyguardDisabled(adminComponent, true)
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_ADJUST_VOLUME)
            if (isAppUpdatesAllowed()) {
                dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_INSTALL_APPS)
            } else {
                dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_INSTALL_APPS)
            }
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_SAFE_BOOT)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_FACTORY_RESET)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_ADD_USER)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_MOUNT_PHYSICAL_MEDIA)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_APPS_CONTROL)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_UNINSTALL_APPS)
            Log.d(
                logTag,
                "Applied kiosk policies. permitted=${dpm.isLockTaskPermitted(packageName)} active=${isCurrentlyInLockTaskMode()}"
            )
        } catch (error: SecurityException) {
            error.printStackTrace()
        } catch (error: IllegalArgumentException) {
            error.printStackTrace()
        }
    }

    private fun applyImmersiveMode() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.hide(
                    WindowInsets.Type.statusBars() or
                        WindowInsets.Type.navigationBars() or
                        WindowInsets.Type.systemBars()
                )
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_DEFAULT
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    private fun getInstalledApps(): List<Map<String, Any>> {
        val launchIntent = Intent(Intent.ACTION_MAIN, null).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }

        val resolvedApps = packageManager.queryIntentActivities(
            launchIntent,
            PackageManager.MATCH_ALL
        )

        return resolvedApps
            .asSequence()
            .filter { resolveInfo -> resolveInfo.activityInfo.packageName != packageName }
            .map { resolveInfo ->
                val activityInfo = resolveInfo.activityInfo
                val packageName = activityInfo.packageName
                val appName = resolveInfo.loadLabel(packageManager)?.toString()
                    ?: packageName
                val iconBytes = drawableToByteArray(resolveInfo.loadIcon(packageManager))

                mapOf(
                    "appName" to appName,
                    "packageName" to packageName,
                    "isSystemApp" to isSystemApp(packageName).toString(),
                    "icon" to iconBytes
                )
            }
            .distinctBy { app -> app["packageName"] as String }
            .sortedWith(
                compareBy<Map<String, Any>> { (it["appName"] as? String)?.lowercase() ?: "" }
                    .thenBy { (it["packageName"] as? String)?.lowercase() ?: "" }
            )
            .toList()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        createSessionAlertChannel(null, true)
    }

    private fun resolveNotificationSoundUri(soundPath: String?): Uri? {
        val normalizedPath = soundPath?.trim().orEmpty()
        if (normalizedPath.isNotEmpty()) {
            val file = File(normalizedPath)
            if (file.exists()) {
                return Uri.fromFile(file)
            }
        }

        return RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
    }

    private fun buildSessionAlertChannelId(soundPath: String?, vibrationEnabled: Boolean): String {
        val soundKey = soundPath?.trim()?.hashCode() ?: 0
        val vibrationKey = if (vibrationEnabled) "v1" else "v0"
        return "${sessionAlertChannelId}_${soundKey}_$vibrationKey"
    }

    private fun createSessionAlertChannel(soundPath: String?, vibrationEnabled: Boolean): String {
        val channelId = buildSessionAlertChannelId(soundPath, vibrationEnabled)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return channelId
        }

        val manager = getSystemService(NotificationManager::class.java) ?: return channelId
        val soundUri = resolveNotificationSoundUri(soundPath)
        val channel = NotificationChannel(
            channelId,
            "Session Alerts",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Warnings when a session is about to expire."
            enableVibration(vibrationEnabled)
            vibrationPattern = if (vibrationEnabled) longArrayOf(0, 300, 200, 300) else longArrayOf(0L)
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

    private fun buildLauncherPendingIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }

        return PendingIntent.getActivity(
            this,
            sessionAlertNotificationId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun showSessionWarningNotification(
        title: String,
        body: String,
        soundPath: String?,
        vibrationEnabled: Boolean
    ) {
        val channelId = createSessionAlertChannel(soundPath, vibrationEnabled)
        val soundUri = resolveNotificationSoundUri(soundPath)
        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setContentIntent(buildLauncherPendingIntent())
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setSound(soundUri)
            if (vibrationEnabled) {
                builder.setVibrate(longArrayOf(0, 300, 200, 300))
            } else {
                builder.setVibrate(longArrayOf(0L))
            }
        }

        val notification = builder.build()

        try {
            NotificationManagerCompat.from(this).notify(sessionAlertNotificationId, notification)
        } catch (error: SecurityException) {
            Log.w(logTag, "Unable to post session warning notification", error)
        }
    }

    private fun cancelSessionWarningNotification() {
        NotificationManagerCompat.from(this).cancel(sessionAlertNotificationId)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }

        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED

        if (!granted) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9001)
        }
    }

    private fun playAudio(audioPath: String, loop: Boolean, volume: Float): Boolean {
        return try {
            stopAudio(immediate = true)
            targetAudioVolume = volume.coerceIn(0f, 1f)
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .build()
                )
                setDataSource(audioPath)
                isLooping = loop
                setVolume(0f, 0f)
                prepare()
                start()
            }
            fadePlayerTo(targetAudioVolume)
            true
        } catch (error: Exception) {
            error.printStackTrace()
            stopAudio(immediate = true)
            false
        }
    }

    private fun stopAudio(immediate: Boolean = false) {
        mediaPlayer?.let { player ->
            cancelActiveAudioFade()

            if (!immediate) {
                fadeOutAndRelease(player)
                return
            }

            try {
                if (player.isPlaying) {
                    player.stop()
                }
            } catch (_: IllegalStateException) {
            }

            try {
                player.reset()
            } catch (_: IllegalStateException) {
            }

            player.release()
        }
        mediaPlayer = null
    }

    private fun playEffectAudio(audioPath: String, volume: Float): Boolean {
        return try {
            stopEffectAudio()
            effectMediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .build()
                )
                setDataSource(audioPath)
                isLooping = false
                setVolume(volume.coerceIn(0f, 1f), volume.coerceIn(0f, 1f))
                setOnCompletionListener {
                    stopEffectAudio()
                }
                prepare()
                start()
            }
            true
        } catch (error: Exception) {
            error.printStackTrace()
            stopEffectAudio()
            false
        }
    }

    private fun stopEffectAudio() {
        effectMediaPlayer?.let { player ->
            try {
                if (player.isPlaying) {
                    player.stop()
                }
            } catch (_: IllegalStateException) {
            }

            try {
                player.reset()
            } catch (_: IllegalStateException) {
            }

            player.release()
        }
        effectMediaPlayer = null
    }

    private fun getAudioDurationMs(audioPath: String): Int? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(audioPath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toIntOrNull()
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun setAudioVolume(volume: Float) {
        targetAudioVolume = volume.coerceIn(0f, 1f)
        fadePlayerTo(targetAudioVolume)
    }

    private fun fadePlayerTo(targetVolume: Float) {
        val player = mediaPlayer ?: return
        cancelActiveAudioFade()
        scheduleFade(
            player = player,
            startVolume = playerCurrentVolume(),
            endVolume = targetVolume,
            onComplete = null
        )
    }

    private fun fadeOutAndRelease(player: MediaPlayer) {
        val closingPlayer = player
        scheduleFade(
            player = closingPlayer,
            startVolume = playerCurrentVolume(),
            endVolume = 0f,
            onComplete = {
                releasePlayer(closingPlayer)
                if (mediaPlayer === closingPlayer) {
                    mediaPlayer = null
                }
            }
        )
    }

    private fun scheduleFade(
        player: MediaPlayer,
        startVolume: Float,
        endVolume: Float,
        onComplete: (() -> Unit)?
    ) {
        val clampedStart = startVolume.coerceIn(0f, 1f)
        val clampedEnd = endVolume.coerceIn(0f, 1f)
        val stepDelay = (audioFadeDurationMs / audioFadeSteps).coerceAtLeast(1L)
        var stepIndex = 0

        lateinit var runnable: Runnable
        runnable = Runnable {
            if (mediaPlayer !== player) {
                onComplete?.invoke()
                return@Runnable
            }

            val progress = stepIndex.toFloat() / audioFadeSteps.toFloat()
            val volume = clampedStart + ((clampedEnd - clampedStart) * progress)
            try {
                player.setVolume(volume, volume)
            } catch (_: IllegalStateException) {
                onComplete?.invoke()
                return@Runnable
            }

            if (stepIndex >= audioFadeSteps) {
                activeAudioFade = null
                onComplete?.invoke()
            } else {
                stepIndex += 1
                activeAudioFade = runnable
                audioFadeHandler.postDelayed(runnable, stepDelay)
            }
        }

        activeAudioFade = runnable
        audioFadeHandler.post(runnable)
    }

    private fun cancelActiveAudioFade() {
        activeAudioFade?.let { audioFadeHandler.removeCallbacks(it) }
        activeAudioFade = null
    }

    private fun playerCurrentVolume(): Float {
        return targetAudioVolume.coerceIn(0f, 1f)
    }

    private fun releasePlayer(player: MediaPlayer) {
        try {
            if (player.isPlaying) {
                player.stop()
            }
        } catch (_: IllegalStateException) {
        }

        try {
            player.reset()
        } catch (_: IllegalStateException) {
        }

        player.release()
    }

    private fun launchApp(targetPackageName: String): Boolean {
        val launchIntent = packageManager.getLaunchIntentForPackage(targetPackageName)
            ?: return false

        allowPackageForAppLaunch(targetPackageName)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            enforceStatusBarLock()
            applyImmersiveMode()
            startActivity(launchIntent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openWifiSettings(): Boolean {
        val wifiIntents = buildWifiIntents()

        for (intent in wifiIntents) {
            val resolvedActivity = packageManager.resolveActivity(
                intent,
                PackageManager.MATCH_DEFAULT_ONLY
            ) ?: continue

            val resolvedPackage = resolvedActivity.activityInfo?.packageName
            allowPackageForAdminLaunch(resolvedPackage)

            try {
                isAdminWifiSessionActive = true
                prepareForAdminSettingsLaunch()
                exitKioskMode()
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Exception) {
                isAdminWifiSessionActive = false
            }
        }

        return false
    }

    private fun getSystemStatus(): Map<String, Any> {
        val batteryManager = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val batteryLevel = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            ?.takeIf { it >= 0 }
            ?: 0

        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val activeNetwork = connectivityManager?.activeNetwork
        val capabilities = connectivityManager?.getNetworkCapabilities(activeNetwork)

        var connectionLabel = "Offline"
        var signalLevel = 0

        if (capabilities != null) {
            when {
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> {
                    connectionLabel = "Wi-Fi"
                    signalLevel = getWifiSignalLevel()
                }
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> {
                    connectionLabel = "Mobile"
                    signalLevel = if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                        4
                    } else {
                        0
                    }
                }
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> {
                    connectionLabel = "Ethernet"
                    signalLevel = 4
                }
            }
        }

        return mapOf(
            "batteryLevel" to batteryLevel,
            "connectionLabel" to connectionLabel,
            "signalLevel" to signalLevel
        )
    }

    private fun getWifiSignalLevel(): Int {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return 0
        val wifiInfo = wifiManager.connectionInfo ?: return 0
        return WifiManager.calculateSignalLevel(wifiInfo.rssi, 5)
    }

    private fun restartApp() {
        scheduleSelfRestart()
        finishAffinity()
    }

    private fun setAppUpdatesAllowed(allowed: Boolean) {
        getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(allowAppUpdatesKey, allowed)
            .apply()

        applyHardKioskPolicies()
    }

    private fun isAppUpdatesAllowed(): Boolean {
        return getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
            .getBoolean(allowAppUpdatesKey, true)
    }

    private fun rebootDevice(): Boolean {
        if (!isDeviceOwnerApp()) {
            return false
        }

        val dpm = devicePolicyManager ?: return false
        return try {
            dpm.reboot(adminComponent)
            true
        } catch (_: SecurityException) {
            false
        } catch (_: IllegalStateException) {
            false
        }
    }

    private fun buildWifiIntents(): List<Intent> {
        val intents = mutableListOf<Intent>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            intents += Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY)
        }

        intents += Intent(Settings.ACTION_WIFI_SETTINGS)
        intents += Intent(Settings.ACTION_WIRELESS_SETTINGS)

        return intents
    }

    private fun allowPackageForAdminLaunch(targetPackageName: String?) {
        if (!isDeviceOwnerApp()) {
            return
        }

        setAllowedLockTaskPackages("com.android.settings", targetPackageName)
    }

    private fun allowPackageForAppLaunch(targetPackageName: String?) {
        if (!isDeviceOwnerApp()) {
            return
        }

        setAllowedLockTaskPackages("com.android.settings", targetPackageName)
    }

    private fun setAllowedLockTaskPackages(vararg packages: String?) {
        if (!isDeviceOwnerApp()) {
            return
        }

        val dpm = devicePolicyManager ?: return
        val allowedPackages = LinkedHashSet<String>().apply {
            add(packageName)
            packages
                .filterNotNull()
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .forEach(::add)
        }

        try {
            dpm.setLockTaskPackages(adminComponent, allowedPackages.toTypedArray())
        } catch (error: SecurityException) {
            error.printStackTrace()
        } catch (error: IllegalArgumentException) {
            error.printStackTrace()
        }
    }

    private fun prepareForAdminSettingsLaunch() {
        if (!isDeviceOwnerApp()) {
            return
        }

        val dpm = devicePolicyManager ?: return
        try {
            dpm.setStatusBarDisabled(adminComponent, false)
        } catch (error: SecurityException) {
            error.printStackTrace()
        } catch (error: IllegalArgumentException) {
            error.printStackTrace()
        }
    }

    private fun restoreKioskRestrictions() {
        if (!isDeviceOwnerApp()) {
            return
        }

        enforceStatusBarLock()
        enterKioskMode()
    }

    private fun enforceStatusBarLock() {
        if (!isDeviceOwnerApp()) {
            return
        }

        val dpm = devicePolicyManager ?: return
        try {
            dpm.setStatusBarDisabled(adminComponent, true)
        } catch (error: SecurityException) {
            error.printStackTrace()
        } catch (error: IllegalArgumentException) {
            error.printStackTrace()
        }
    }

    private fun resetWhitelistedApps(packageNames: List<String>): List<String> {
        return packageNames.filter { packageName ->
            !forceStopAndClear(packageName)
        }
    }

    private fun forceStopAndClear(targetPackageName: String): Boolean {
        val forceStopped = runShellCommand("am force-stop $targetPackageName")
        val cleared = runShellCommand("pm clear $targetPackageName")
        return forceStopped && cleared
    }

    private fun runShellCommand(command: String): Boolean {
        return try {
            val process = ProcessBuilder("sh", "-c", command)
                .redirectErrorStream(true)
                .start()

            process.waitFor(15, TimeUnit.SECONDS) && process.exitValue() == 0
        } catch (_: Exception) {
            false
        }
    }

    private fun scheduleSelfRestart() {
        val restartIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            ?: return

        val pendingIntent = PendingIntent.getActivity(
            this,
            1001,
            restartIntent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
        )

        val alarmManager = getSystemService(AlarmManager::class.java) ?: return
        val triggerAt = System.currentTimeMillis() + 1000

        alarmManager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerAt,
            pendingIntent
        )
    }

    private fun drawableToByteArray(drawable: Drawable): ByteArray {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            drawable.bitmap
        } else {
            val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 96
            val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 96

            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmap ->
                val canvas = Canvas(bitmap)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
            }
        }

        return ByteArrayOutputStream().use { stream ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        }
    }

    private fun isSystemApp(targetPackageName: String): Boolean {
        return try {
            val applicationInfo = packageManager.getApplicationInfo(targetPackageName, 0)
            (applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }
}
