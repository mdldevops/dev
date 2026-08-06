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
import android.content.BroadcastReceiver
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Bundle
import android.os.Build
import android.os.Looper
import android.os.PowerManager
import android.view.View
import android.view.KeyEvent
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.content.pm.ApplicationInfo
import android.content.pm.ActivityInfo
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
import android.app.KeyguardManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.util.LinkedHashSet
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val EXTRA_SESSION_EXPIRED = "session_expired"
        const val EXTRA_FORCE_SCREEN_ON = "force_screen_on"
        const val EXTRA_ENFORCE_CLOSE_RETURN = "enforce_close_return"
    }

    private val logTag = "PisoStreamKiosk"
    private val channelName = "com.example.piso_stream/installed_apps"
    private val sessionAlertChannelId = "session_alerts"
    private val sessionAlertNotificationId = 3101
    private val sessionWarnOneMinuteRequestCode = 3102
    private val sessionWarnTwentySecondsRequestCode = 3103
    private val sessionExpiredRequestCode = 3104
    private val sessionExpiredLaunchRequestCode = 3105
    private val policyPrefsName = "kiosk_policy_prefs"
    private val flutterPrefsName = "FlutterSharedPreferences"
    private val currentCustomerRolePrefKey = "flutter.current_customer_role"
    private val sessionExpiresAtPrefKey = "flutter.session_expires_at"
    private val kioskModeEnabledPrefKey = "flutter.kiosk_mode_enabled"
    private val audioVolumePrefKey = "flutter.audio_volume"
    private val userAudioVolumePrefKey = "flutter.user_audio_volume"
    private val lastLaunchedAppKey = "last_launched_app_package"
    private val allowAppUpdatesKey = "allow_app_updates"
    private val youtubePackageName = "com.google.android.youtube"
    private val playStorePackageName = "com.android.vending"
    private val packageInstallerPackageNames = arrayOf(
        "com.google.android.packageinstaller",
        "com.android.packageinstaller",
        "com.android.permissioncontroller",
        "com.miui.packageinstaller"
    )
    private val finalCountdownLockSeconds = 20L
    private val homeShortcutWindowMs = 2000L
    private val audioFadeDurationMs = 500L
    private val audioFadeSteps = 10
    private var isAdminWifiSessionActive = false
    private var isPolicyExemptLaunchActive = false
    private var mediaPlayer: MediaPlayer? = null
    private var effectMediaPlayer: MediaPlayer? = null
    private val audioFadeHandler = Handler(Looper.getMainLooper())
    private var activeAudioFade: Runnable? = null
    private var targetAudioVolume = 0.5f
    private var sessionWakeLock: PowerManager.WakeLock? = null
    private var lastHomeLauncherTapAtMs = 0L
    private val resetExecutor = Executors.newSingleThreadExecutor()
    private val adminComponent by lazy {
        ComponentName(this, KioskDeviceAdminReceiver::class.java)
    }
    private val devicePolicyManager by lazy {
        getSystemService(DevicePolicyManager::class.java)
    }
    private val audioManager by lazy {
        getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }
    private val batteryStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_BATTERY_CHANGED,
                Intent.ACTION_POWER_CONNECTED,
                Intent.ACTION_POWER_DISCONNECTED -> {
                    ChargingMonitorReceiver.triggerRefresh(applicationContext, false)
                }
            }
        }
    }
    private var batteryReceiverRegistered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ChargingMonitorReceiver.scheduleNext(this, 5000L)
        ChargingMonitorService.start(this)
        registerBatteryStateReceiver()
        adoptDeviceRotationPreference()
        handleLaunchIntent(intent)
        createNotificationChannel()
        requestNotificationPermissionIfNeeded()
        applySavedAudioVolumePreference()
        if (isKioskModeEnabled()) {
            applyImmersiveMode()
        } else {
            restoreNormalSystemUi()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLaunchIntent(intent)
    }

    override fun onDestroy() {
        if (batteryReceiverRegistered) {
            try {
                unregisterReceiver(batteryStateReceiver)
            } catch (_: Exception) {
            }
            batteryReceiverRegistered = false
        }
        releaseSessionWakeLock()
        stopAudio(immediate = true)
        stopEffectAudio()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledApps" -> result.success(getInstalledApps())
                    "getInstalledAppsForPackages" -> {
                        val packageNames = call.argument<List<String>>("packageNames").orEmpty()
                        result.success(getInstalledAppsForPackages(packageNames))
                    }
                    "enterKioskMode" -> {
                        enterKioskMode()
                        result.success(null)
                    }
                    "exitKioskMode" -> {
                        exitKioskMode()
                        result.success(null)
                    }
                    "setKioskModeEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        setKioskModeEnabled(enabled)
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
                        resetExecutor.execute {
                            val failures = resetWhitelistedApps(packageNames)
                            runOnUiThread {
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
                        }
                    }
                    "launchApp" -> {
                        val packageName = call.argument<String>("packageName")
                        val allowPlayStore = call.argument<Boolean>("allowPlayStore") ?: false

                        if (packageName.isNullOrBlank()) {
                            result.error("INVALID_PACKAGE", "Package name is required.", null)
                            return@setMethodCallHandler
                        }

                        if (isFinalCountdownLaunchLocked()) {
                            result.error(
                                "FINAL_COUNTDOWN_LOCKED",
                                "App launching is locked during the final 20 seconds.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        if (launchApp(packageName, allowPlayStore)) {
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
                    "returnLauncherToFront" -> {
                        returnLauncherToFront()
                        result.success(null)
                    }
                    "scheduleSessionMonitoring" -> {
                        val expiresAtMs = call.argument<Long>("expiresAtMs")
                        val warnOneMinuteAtMs = call.argument<Long>("warnOneMinuteAtMs")
                        val warnTwentySecondsAtMs = call.argument<Long>("warnTwentySecondsAtMs")
                        if (expiresAtMs == null) {
                            result.error("INVALID_EXPIRES_AT", "expiresAtMs is required.", null)
                        } else {
                            scheduleSessionMonitoring(
                                expiresAtMs = expiresAtMs,
                                warnOneMinuteAtMs = warnOneMinuteAtMs,
                                warnTwentySecondsAtMs = warnTwentySecondsAtMs
                            )
                            result.success(null)
                        }
                    }
                    "cancelSessionMonitoring" -> {
                        cancelSessionMonitoring()
                        result.success(null)
                    }
                    "canDrawTimeOverlay" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "openTimeOverlayPermissionSettings" -> {
                        if (openTimeOverlayPermissionSettings()) {
                            result.success(null)
                        } else {
                            result.error(
                                "OVERLAY_SETTINGS_UNAVAILABLE",
                                "Unable to open overlay permission settings.",
                                null
                            )
                        }
                    }
                    "startRemainingTimeOverlay" -> {
                        val displayRemainingMs =
                            (call.argument<Number>("displayRemainingMs"))?.toLong()
                        val countdownMultiplier =
                            (call.argument<Number>("countdownMultiplier"))?.toDouble() ?: 1.0
                        if (displayRemainingMs == null) {
                            result.error(
                                "INVALID_DISPLAY_REMAINING",
                                "displayRemainingMs is required for the time overlay.",
                                null
                            )
                        } else {
                            startRemainingTimeOverlay(displayRemainingMs, countdownMultiplier)
                            result.success(null)
                        }
                    }
                    "startOpenTimeOverlay" -> {
                        startOpenTimeOverlay()
                        result.success(null)
                    }
                    "stopRemainingTimeOverlay" -> {
                        stopRemainingTimeOverlay()
                        result.success(null)
                    }
                    "testRemainingTimeOverlay" -> {
                        startRemainingTimeOverlay(
                            TimeUnit.MINUTES.toMillis(2),
                            1.0
                        )
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermissionIfNeeded()
                        result.success(null)
                    }
                    "refreshChargingMonitor" -> {
                        val resetDecisionCache =
                            call.argument<Boolean>("resetDecisionCache") ?: false
                        ChargingMonitorService.start(this)
                        if (resetDecisionCache) {
                            ChargingMonitorReceiver.triggerRefresh(
                                this,
                                resetDecisionCache = true
                            )
                        }
                        try {
                            result.success(ChargingMonitorReceiver.evaluateNow(this))
                        } catch (error: Exception) {
                            result.error(
                                "CHARGING_MONITOR_FAILED",
                                error.message ?: "Charging monitor failed.",
                                null
                            )
                        }
                    }
                    "prepareForAppUpdate" -> {
                        prepareForAppUpdate()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        stopRemainingTimeOverlay()
        ChargingMonitorService.start(this)
        ChargingMonitorReceiver.triggerRefresh(this, resetDecisionCache = false)
        adoptDeviceRotationPreference()
        applySavedAudioVolumePreference()
        if (!isKioskModeEnabled()) {
            disableKioskModeSafely(returnToSystemHome = false)
            return
        }
        applyImmersiveMode()
        if (isAdminWifiSessionActive) {
            isAdminWifiSessionActive = false
            restoreKioskRestrictions()
        } else if (isPolicyExemptLaunchActive) {
            isPolicyExemptLaunchActive = false
            restoreKioskRestrictions()
        } else {
            enterKioskMode()
        }
    }

    private fun handleLaunchIntent(intent: Intent?) {
        if (isHomeLauncherIntent(intent)) {
            handleHomeLauncherShortcut()
        }

        if (intent?.getBooleanExtra(EXTRA_ENFORCE_CLOSE_RETURN, false) == true) {
            stopRemainingTimeOverlay()
            closeCurrentOpenAppBeforeReturn()
            intent.removeExtra(EXTRA_ENFORCE_CLOSE_RETURN)
        }

        if (intent?.getBooleanExtra(EXTRA_FORCE_SCREEN_ON, false) == true) {
            wakeAndKeepScreenOn()
            intent.removeExtra(EXTRA_FORCE_SCREEN_ON)
        }

        if (intent?.getBooleanExtra(EXTRA_SESSION_EXPIRED, false) != true) {
            return
        }

        val prefs = getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean("flutter.session_expired_pending", true)
            .remove("flutter.current_customer_username")
            .remove("flutter.current_customer_role")
            .remove("flutter.customer_idle_deadline")
            .apply()

        // Force stop the last launched app if it was not the current app
        val kioskPolicyPrefs = getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
        val lastLaunchedAppPackage = kioskPolicyPrefs.getString(lastLaunchedAppKey, null)
        if (lastLaunchedAppPackage != null && lastLaunchedAppPackage != packageName) {
            Log.d(logTag, "Force-stopping last launched app: $lastLaunchedAppPackage")
            forceStopTrackedPackage(lastLaunchedAppPackage)
            kioskPolicyPrefs.edit().remove(lastLaunchedAppKey).apply()
        }
        stopRemainingTimeOverlay()
        intent.removeExtra(EXTRA_SESSION_EXPIRED)
        Log.d(logTag, "Handled session-expired launch intent")
    }

    private fun isHomeLauncherIntent(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_MAIN) {
            return false
        }

        val categories = intent.categories ?: return false
        return categories.contains(Intent.CATEGORY_HOME)
    }

    private fun handleHomeLauncherShortcut() {
        if (!hasActiveSessionShortcutTarget()) {
            lastHomeLauncherTapAtMs = 0L
            return
        }

        val now = System.currentTimeMillis()
        val isDoubleTap = now - lastHomeLauncherTapAtMs <= homeShortcutWindowMs
        lastHomeLauncherTapAtMs = now

        if (!isDoubleTap) {
            Log.d(logTag, "Home shortcut armed for active session")
            return
        }

        Log.d(logTag, "Double-home detected, closing current app and returning to menu")
        wakeAndKeepScreenOn()
        closeCurrentOpenAppBeforeReturn()
        if (isKioskModeEnabled()) {
            applyImmersiveMode()
        }
        lastHomeLauncherTapAtMs = 0L
    }

    private fun registerBatteryStateReceiver() {
        if (batteryReceiverRegistered) {
            return
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }

        try {
            registerReceiver(batteryStateReceiver, filter)
            batteryReceiverRegistered = true
        } catch (error: Exception) {
            Log.w(logTag, "Unable to register battery receiver", error)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && isKioskModeEnabled()) {
            applyImmersiveMode()
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isKioskModeEnabled() &&
            (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN ||
            event.keyCode == KeyEvent.KEYCODE_VOLUME_MUTE)
        ) {
            applySavedAudioVolumePreference()
            return true
        }

        return super.dispatchKeyEvent(event)
    }

    private fun enterKioskMode() {
        if (!isKioskModeEnabled()) {
            disableKioskModeSafely()
            return
        }
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

    private fun setKioskModeEnabled(enabled: Boolean) {
        getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(kioskModeEnabledPrefKey, enabled)
            .apply()

        if (enabled) {
            enableKioskModeSafely()
            return
        }

        stopRemainingTimeOverlay()
        disableKioskModeSafely(returnToSystemHome = true)
    }

    private fun enableKioskModeSafely() {
        try {
            applyHardKioskPolicies()
            if (!isCurrentlyInLockTaskMode()) {
                enterKioskMode()
            }
        } catch (error: Exception) {
            Log.e(logTag, "Failed to enable kiosk mode safely", error)
        }
    }

    private fun disableKioskModeSafely(returnToSystemHome: Boolean = false) {
        restoreNormalSystemUi()

        try {
            exitKioskMode()
        } catch (error: Exception) {
            Log.e(logTag, "Failed while exiting kiosk mode", error)
        }

        try {
            clearHardKioskPolicies()
        } catch (error: Exception) {
            Log.e(logTag, "Failed while clearing kiosk policies", error)
        }

        try {
            exitKioskMode()
        } catch (error: Exception) {
            Log.e(logTag, "Failed while exiting kiosk mode", error)
        }

        if (returnToSystemHome) {
            Handler(Looper.getMainLooper()).postDelayed(
                { launchSystemHomeAndFinish() },
                350L
            )
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
                dpm.setLockTaskFeatures(
                    adminComponent,
                    DevicePolicyManager.LOCK_TASK_FEATURE_HOME
                )
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
            if (shouldAllowAppInstalls()) {
                dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_INSTALL_APPS)
            } else {
                dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_INSTALL_APPS)
            }
            syncProtectedAppVisibility()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                dpm.addUserRestriction(adminComponent, "no_app_multiwindow")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                dpm.addUserRestriction(adminComponent, "no_multiwindow")
            }
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_FACTORY_RESET)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_SAFE_BOOT)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_ADD_USER)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_MOUNT_PHYSICAL_MEDIA)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_APPS_CONTROL)
            dpm.addUserRestriction(adminComponent, UserManager.DISALLOW_UNINSTALL_APPS)
            Log.d(
                logTag,
                "Applied kiosk policies. permitted=${dpm.isLockTaskPermitted(packageName)} active=${isCurrentlyInLockTaskMode()}"
            )
        } catch (error: Exception) {
            Log.e(logTag, "Failed to apply kiosk policies", error)
        }
    }

    private fun clearHardKioskPolicies() {
        if (!isDeviceOwnerApp()) {
            return
        }

        val dpm = devicePolicyManager ?: return

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                dpm.setLockTaskFeatures(
                    adminComponent,
                    DevicePolicyManager.LOCK_TASK_FEATURE_NONE
                )
            }
            dpm.clearPackagePersistentPreferredActivities(adminComponent, packageName)
            dpm.setLockTaskPackages(adminComponent, emptyArray())
            dpm.setStatusBarDisabled(adminComponent, false)
            dpm.setKeyguardDisabled(adminComponent, false)
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_INSTALL_APPS)
            dpm.clearUserRestriction(adminComponent, "no_install_unknown_sources")
            dpm.clearUserRestriction(adminComponent, "no_install_unknown_sources_globally")
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_SAFE_BOOT)
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_ADD_USER)
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_MOUNT_PHYSICAL_MEDIA)
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_APPS_CONTROL)
            dpm.clearUserRestriction(adminComponent, UserManager.DISALLOW_UNINSTALL_APPS)
            dpm.clearUserRestriction(adminComponent, "no_app_multiwindow")
            dpm.clearUserRestriction(adminComponent, "no_multiwindow")
            restoreInstallAccess(dpm)
            Log.d(logTag, "Cleared kiosk policies and restored normal device behavior")
        } catch (error: Exception) {
            Log.e(logTag, "Failed to clear kiosk policies", error)
        }
    }

    private fun restoreInstallAccess(dpm: DevicePolicyManager) {
        val packagesToRestore = arrayOf(playStorePackageName, *packageInstallerPackageNames)
        for (targetPackage in packagesToRestore) {
            try {
                dpm.setApplicationHidden(adminComponent, targetPackage, false)
            } catch (error: Exception) {
                Log.w(logTag, "Unable to unhide install package $targetPackage", error)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                dpm.setPackagesSuspended(adminComponent, packagesToRestore, false)
            } catch (error: Exception) {
                Log.w(logTag, "Unable to unsuspend install packages", error)
            }
        }
    }

    private fun restoreNormalSystemUi() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(
                WindowInsets.Type.statusBars() or
                    WindowInsets.Type.navigationBars() or
                    WindowInsets.Type.systemBars()
            )
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    private fun launchSystemHomeAndFinish() {
        restoreNormalSystemUi()
        val homeIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        try {
            val resolvedHome = packageManager.resolveActivity(
                homeIntent,
                PackageManager.MATCH_DEFAULT_ONLY
            )
            if (resolvedHome?.activityInfo?.packageName == packageName) {
                val homeSettingsIntent = Intent(Settings.ACTION_HOME_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(homeSettingsIntent)
            } else {
                startActivity(homeIntent)
            }
        } catch (error: Exception) {
            Log.w(logTag, "Unable to launch system home after kiosk disable", error)
        }

        try {
            finishAndRemoveTask()
        } catch (_: Exception) {
            finish()
        }
    }

    private fun applyImmersiveMode() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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

    private fun adoptDeviceRotationPreference() {
        try {
            requestedOrientation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                ActivityInfo.SCREEN_ORIENTATION_FULL_USER
            } else {
                ActivityInfo.SCREEN_ORIENTATION_USER
            }
            Log.d(logTag, "Adopting device rotation preference")
        } catch (error: Exception) {
            Log.w(logTag, "Unable to adopt device rotation preference", error)
        }
    }

    private fun wakeAndKeepScreenOn() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }

            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )

            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && keyguardManager != null) {
                keyguardManager.requestDismissKeyguard(this, null)
            }

            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (sessionWakeLock?.isHeld != true && powerManager != null) {
                @Suppress("DEPRECATION")
                sessionWakeLock = powerManager.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP or
                        PowerManager.ON_AFTER_RELEASE,
                    "$packageName:session-warning"
                ).apply {
                    acquire(15_000L)
                }
            }

            if (isKioskModeEnabled()) {
                applyImmersiveMode()
            }
            Log.d(logTag, "Requested wake-and-screen-on for launcher return")
        } catch (error: Exception) {
            Log.w(logTag, "Unable to wake screen for launcher return", error)
        }
    }

    private fun releaseSessionWakeLock() {
        try {
            if (sessionWakeLock?.isHeld == true) {
                sessionWakeLock?.release()
            }
        } catch (_: Exception) {
        } finally {
            sessionWakeLock = null
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

    private fun getInstalledAppsForPackages(packageNames: List<String>): List<Map<String, Any>> {
        return packageNames
            .asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != packageName }
            .mapNotNull(::resolveInstalledAppForPackage)
            .toList()
    }

    private fun resolveInstalledAppForPackage(targetPackageName: String): Map<String, Any>? {
        return try {
            val launchIntent = resolveLaunchIntentForPackage(targetPackageName)
            val appLabel = if (launchIntent?.component != null) {
                val resolveInfo = packageManager.resolveActivity(launchIntent, PackageManager.MATCH_ALL)
                resolveInfo?.loadLabel(packageManager)?.toString()
            } else {
                null
            }

            val applicationInfo = packageManager.getApplicationInfo(targetPackageName, 0)
            val appName = appLabel
                ?: packageManager.getApplicationLabel(applicationInfo)?.toString()
                ?: targetPackageName
            val iconBytes = drawableToByteArray(packageManager.getApplicationIcon(applicationInfo))

            mapOf(
                "appName" to appName,
                "packageName" to targetPackageName,
                "icon" to iconBytes
            )
        } catch (error: Exception) {
            Log.w(logTag, "Unable to resolve installed app for package $targetPackageName", error)
            null
        }
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

    private fun scheduleSessionMonitoring(
        expiresAtMs: Long,
        warnOneMinuteAtMs: Long?,
        warnTwentySecondsAtMs: Long?
    ) {
        cancelSessionMonitoring()
        val alarmManager = getSystemService(AlarmManager::class.java) ?: return
        val now = System.currentTimeMillis()

        if (warnOneMinuteAtMs != null && warnOneMinuteAtMs > now) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                warnOneMinuteAtMs,
                buildSessionAlarmPendingIntent(
                    requestCode = sessionWarnOneMinuteRequestCode,
                    action = KioskSessionAlarmReceiver.ACTION_WARN_ONE_MINUTE,
                    title = "Less than 1 minute remaining",
                    body = "Your session is almost over. Insert coins now if you want to continue."
                )
            )
        }

        if (warnTwentySecondsAtMs != null && warnTwentySecondsAtMs > now) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                warnTwentySecondsAtMs,
                buildSessionAlarmPendingIntent(
                    requestCode = sessionWarnTwentySecondsRequestCode,
                    action = KioskSessionAlarmReceiver.ACTION_WARN_TWENTY_SECONDS,
                    title = "20 seconds remaining",
                    body = "Returning to launcher. Insert coins now if you want to continue your session."
                )
            )
            // Add a direct launch intent for the 20-second warning to bring MainActivity to front
            // Use a distinct request code to avoid conflicts with the alarm receiver's PendingIntent.
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                warnTwentySecondsAtMs,
                buildReturnToLauncherPendingIntent(
                    requestCode = sessionWarnTwentySecondsRequestCode + 100,
                    sessionExpired = false, // This is a warning, not an expiry
                    enforceCloseReturn = true
                )
            )
        }

        if (expiresAtMs > now) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                expiresAtMs,
                buildSessionAlarmPendingIntent(
                    requestCode = sessionExpiredRequestCode,
                    action = KioskSessionAlarmReceiver.ACTION_SESSION_EXPIRED
                )
            )
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                expiresAtMs,
                buildSessionExpiredLaunchPendingIntent()
            )
        }
    }

    private fun cancelSessionMonitoring() {
        stopRemainingTimeOverlay()
        val alarmManager = getSystemService(AlarmManager::class.java) ?: return
        alarmManager.cancel(
            buildSessionAlarmPendingIntent(
                requestCode = sessionWarnOneMinuteRequestCode,
                action = KioskSessionAlarmReceiver.ACTION_WARN_ONE_MINUTE
            )
        )
        alarmManager.cancel(
            buildSessionAlarmPendingIntent(
                requestCode = sessionWarnTwentySecondsRequestCode,
                action = KioskSessionAlarmReceiver.ACTION_WARN_TWENTY_SECONDS
            )
        )
        // Cancel the new 20-second launch intent
        alarmManager.cancel(
            buildReturnToLauncherPendingIntent(
                requestCode = sessionWarnTwentySecondsRequestCode + 100,
                sessionExpired = false
            )
        )
        alarmManager.cancel(
            buildSessionAlarmPendingIntent(
                requestCode = sessionExpiredRequestCode,
                action = KioskSessionAlarmReceiver.ACTION_SESSION_EXPIRED
            )
        )
        alarmManager.cancel(buildSessionExpiredLaunchPendingIntent())
    }

    private fun buildSessionAlarmPendingIntent(
        requestCode: Int,
        action: String,
        title: String? = null,
        body: String? = null
    ): PendingIntent {
        val intent = Intent(this, KioskSessionAlarmReceiver::class.java).apply {
            this.action = action
            if (title != null) {
                putExtra("title", title)
            }
            if (body != null) {
                putExtra("body", body)
            }
        }

        return PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildSessionExpiredLaunchPendingIntent(): PendingIntent {
        return buildReturnToLauncherPendingIntent(
            requestCode = sessionExpiredLaunchRequestCode,
            sessionExpired = true
        )
    }

    private fun buildReturnToLauncherPendingIntent(
        requestCode: Int,
        sessionExpired: Boolean = false,
        enforceCloseReturn: Boolean = false
    ): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            if (sessionExpired) {
                putExtra(EXTRA_SESSION_EXPIRED, true)
            }
            if (enforceCloseReturn) {
                putExtra(EXTRA_ENFORCE_CLOSE_RETURN, true)
            }
            putExtra(EXTRA_FORCE_SCREEN_ON, true)
        }

        return PendingIntent.getActivity(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun returnLauncherToFront() {
        stopRemainingTimeOverlay()
        wakeAndKeepScreenOn()
        closeCurrentOpenAppBeforeReturn()

        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
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
            Log.d(logTag, "Moved existing launcher task to front")
        }

        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags =
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                putExtra(EXTRA_ENFORCE_CLOSE_RETURN, true)
                putExtra(EXTRA_FORCE_SCREEN_ON, true)
            }
            startActivity(intent)
        } catch (error: Exception) {
            Log.w(logTag, "Unable to return launcher to front", error)
        }
    }

    private fun closeCurrentOpenAppBeforeReturn() {
        val prefs = getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
        val fallbackPackage = prefs.getString(lastLaunchedAppKey, null)
            ?.trim()
            .orEmpty()
        val targetPackages = resolvePackagesToClose(fallbackPackage)

        if (targetPackages.isEmpty()) {
            val debugSummary =
                "pkgs=<none> fallback=${if (fallbackPackage.isEmpty()) "<none>" else fallbackPackage}"
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit()
                .putString("flutter.native_close_debug", debugSummary)
                .apply()
            Log.d(logTag, "closeCurrentOpenAppBeforeReturn $debugSummary")
            return
        }

        val revokedFromLockTask = revokePackageFromLockTaskAllowlistForReturn()
        var closeApplied = false
        val closeResults = targetPackages.map { targetPackage ->
            val suspendedByPolicy = temporarilySuspendAndRestorePackage(targetPackage)
            val hiddenByPolicy = temporarilyHideAndRestorePackage(targetPackage)
            val forceStopped = aggressivelyForceStopPackage(targetPackage)
            closeApplied = closeApplied || suspendedByPolicy || hiddenByPolicy || forceStopped
            "$targetPackage[suspend=$suspendedByPolicy hide=$hiddenByPolicy force=$forceStopped]"
        }
        val debugSummary =
            "pkgs=${closeResults.joinToString(",")} revoke=$revokedFromLockTask"

        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit()
            .putString("flutter.native_close_debug", debugSummary)
            .apply()

        Log.d(logTag, "closeCurrentOpenAppBeforeReturn $debugSummary")
        if (closeApplied) {
            prefs.edit().remove(lastLaunchedAppKey).apply()
        } else {
            Log.d(logTag, "Retaining fallback package for retry: $fallbackPackage")
        }
    }

    private fun resolvePackagesToClose(fallbackPackage: String): List<String> {
        val targetPackages = LinkedHashSet<String>()
        val topPackage = resolveCurrentOpenAppPackage(fallbackPackage = "")

        if (
            topPackage.isNotBlank() &&
            topPackage != packageName &&
            topPackage != "com.android.settings"
        ) {
            targetPackages.add(topPackage)
        }

        if (
            fallbackPackage.isNotBlank() &&
            fallbackPackage != packageName &&
            fallbackPackage != "com.android.settings"
        ) {
            targetPackages.add(fallbackPackage)
        }

        return targetPackages.toList()
    }

    private fun resolveCurrentOpenAppPackage(fallbackPackage: String): String {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager

        val topPackage = try {
            @Suppress("DEPRECATION")
            activityManager
                ?.getRunningTasks(5)
                ?.asSequence()
                ?.mapNotNull { taskInfo -> taskInfo.topActivity?.packageName }
                ?.firstOrNull { targetPackage ->
                    targetPackage.isNotBlank() && targetPackage != packageName
                }
                .orEmpty()
        } catch (_: Exception) {
            ""
        }

        if (topPackage.isNotEmpty()) {
            Log.d(logTag, "Resolved current open app package from running tasks: $topPackage")
            return topPackage
        }

        if (fallbackPackage.isNotEmpty()) {
            Log.d(logTag, "Falling back to last launched app package: $fallbackPackage")
        }

        return fallbackPackage
    }

    private fun revokePackageFromLockTaskAllowlistForReturn(): Boolean {
        if (!isDeviceOwnerApp()) {
            return false
        }

        val dpm = devicePolicyManager ?: return false
        return try {
            dpm.setLockTaskPackages(adminComponent, arrayOf(packageName, "com.android.settings"))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                dpm.setLockTaskFeatures(
                    adminComponent,
                    DevicePolicyManager.LOCK_TASK_FEATURE_HOME
                )
            }
            Log.d(logTag, "Revoked other packages from lock-task allowlist")
            true
        } catch (error: Exception) {
            Log.w(logTag, "Failed to revoke lock-task allowlist: ${error.message}")
            false
        }
    }

    private fun temporarilyHideAndRestorePackage(targetPackage: String): Boolean {
        if (!isDeviceOwnerApp()) {
            return false
        }

        val dpm = devicePolicyManager ?: return false
        return try {
            val hidden = dpm.setApplicationHidden(adminComponent, targetPackage, true)
            val restored = dpm.setApplicationHidden(adminComponent, targetPackage, false)
            Log.d(
                logTag,
                "temporarilyHideAndRestorePackage package=$targetPackage hidden=$hidden restored=$restored"
            )
            hidden || restored
        } catch (error: Exception) {
            Log.w(logTag, "Failed to hide/unhide package $targetPackage: ${error.message}")
            false
        }
    }

    private fun temporarilySuspendAndRestorePackage(targetPackage: String): Boolean {
        if (!isDeviceOwnerApp() || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return false
        }

        val dpm = devicePolicyManager ?: return false
        return try {
            dpm.setPackagesSuspended(adminComponent, arrayOf(targetPackage), true)
            Handler(Looper.getMainLooper()).postDelayed(
                {
                    try {
                        dpm.setPackagesSuspended(adminComponent, arrayOf(targetPackage), false)
                        Log.d(logTag, "Restored suspended package $targetPackage")
                    } catch (error: Exception) {
                        Log.w(
                            logTag,
                            "Failed to restore suspended package $targetPackage: ${error.message}"
                        )
                    }
                },
                1500L
            )
            Log.d(logTag, "Suspended package $targetPackage")
            true
        } catch (error: Exception) {
            Log.w(logTag, "Failed to suspend package $targetPackage: ${error.message}")
            false
        }
    }

    private fun prepareForAppUpdate() {
        setAppUpdatesAllowed(true)
        exitKioskMode()
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
            applySystemMediaVolume(targetAudioVolume)
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
            applySystemMediaVolume(volume.coerceIn(0f, 1f))
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
        applySystemMediaVolume(targetAudioVolume)
        fadePlayerTo(targetAudioVolume)
    }

    private fun applySavedAudioVolumePreference() {
        val prefs = getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
        val rawValue = prefs.all[userAudioVolumePrefKey] ?: prefs.all[audioVolumePrefKey]
        val savedVolume = when (rawValue) {
            is Float -> rawValue
            is Double -> rawValue.toFloat()
            is Int -> rawValue.toFloat()
            is Long -> java.lang.Double.longBitsToDouble(rawValue).toFloat()
            is String -> rawValue.toFloatOrNull() ?: 0.5f
            else -> 0.5f
        }.coerceIn(0f, 1f)
        targetAudioVolume = savedVolume
        applySystemMediaVolume(savedVolume)
        mediaPlayer?.let { player ->
            try {
                player.setVolume(savedVolume, savedVolume)
            } catch (_: IllegalStateException) {
            }
        }
        effectMediaPlayer?.let { player ->
            try {
                player.setVolume(savedVolume, savedVolume)
            } catch (_: IllegalStateException) {
            }
        }
    }

    private fun applySystemMediaVolume(normalizedVolume: Float) {
        val manager = audioManager ?: return
        val maxVolume = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (maxVolume <= 0) {
            return
        }

        val clamped = normalizedVolume.coerceIn(0f, 1f)
        var targetVolume = (clamped * maxVolume)
            .toInt()
            .coerceIn(0, maxVolume)
        if (clamped > 0f && targetVolume == 0) {
            targetVolume = 1
        }
        manager.setStreamVolume(AudioManager.STREAM_MUSIC, targetVolume, 0)
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

    private fun launchApp(targetPackageName: String, allowPlayStore: Boolean): Boolean {
        val launchIntent = resolveLaunchIntentForPackage(targetPackageName)
        if (launchIntent == null) {
            Log.w(logTag, "No launch intent resolved for package: $targetPackageName")
            return false
        }

        val isPolicyExemptPackage = isPolicyExemptLaunchPackage(targetPackageName)
        val kioskModeEnabled = isKioskModeEnabled()
        if (kioskModeEnabled && !isPolicyExemptPackage) {
            applyHardKioskPolicies()
            allowPackageForAppLaunch(
                targetPackageName,
                if (allowPlayStore) "com.android.vending" else null
            )
        }
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ChargingMonitorReceiver.triggerRefresh(this, false)

        if (kioskModeEnabled && isPolicyExemptPackage) {
            return try {
                isPolicyExemptLaunchActive = true
                prepareForAdminSettingsLaunch()
                exitKioskMode()
                Handler(Looper.getMainLooper()).post {
                    try {
                        startActivity(launchIntent)
                    } catch (error: Exception) {
                        stopRemainingTimeOverlay()
                        isPolicyExemptLaunchActive = false
                        Log.w(logTag, "Failed to launch exempt package $targetPackageName: ${error.message}")
                    }
                }
                getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
                    .edit()
                    .putString(lastLaunchedAppKey, targetPackageName)
                    .apply()
                true
            } catch (error: Exception) {
                isPolicyExemptLaunchActive = false
                Log.w(logTag, "Failed to prepare exempt launch for package $targetPackageName: ${error.message}")
                false
            }
        }

        return try {
            applySavedAudioVolumePreference()
            if (kioskModeEnabled) {
                enforceStatusBarLock()
            }
            applyImmersiveMode()
            startActivity(launchIntent)
            getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
                .edit()
                .putString(lastLaunchedAppKey, targetPackageName)
                .apply()
            true
        } catch (error: Exception) {
            stopRemainingTimeOverlay()
            Log.w(logTag, "Failed to launch package $targetPackageName: ${error.message}")
            false
        }
    }

    private fun startRemainingTimeOverlayIfPermitted() {
        val expiresAtMs = getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
            .getLong(sessionExpiresAtPrefKey, 0L)
        val displayRemainingMs =
            (expiresAtMs - System.currentTimeMillis()).coerceAtLeast(0L)
        startRemainingTimeOverlay(displayRemainingMs, 1.0)
    }

    private fun startRemainingTimeOverlay(displayRemainingMs: Long, countdownMultiplier: Double) {
        if (displayRemainingMs <= 0L) {
            stopRemainingTimeOverlay()
            return
        }

        if (!Settings.canDrawOverlays(this)) {
            Log.d(logTag, "Remaining time overlay permission not granted")
            return
        }

        Log.d(
            logTag,
            "Starting remaining time overlay displayRemainingMs=$displayRemainingMs multiplier=$countdownMultiplier"
        )
        RemainingTimeOverlayController.showCountdown(this, displayRemainingMs, countdownMultiplier)
    }

    private fun startOpenTimeOverlay() {
        if (!Settings.canDrawOverlays(this)) {
            Log.d(logTag, "Open-time overlay permission not granted")
            return
        }

        Log.d(logTag, "Starting open-time overlay")
        RemainingTimeOverlayController.showLabel(this, "OPEN TIME")
    }

    private fun stopRemainingTimeOverlay() {
        RemainingTimeOverlayController.hide()
    }

    private fun openTimeOverlayPermissionSettings(): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (error: Exception) {
            Log.w(logTag, "Unable to open overlay permission settings", error)
            false
        }
    }

    private fun isPolicyExemptLaunchPackage(targetPackageName: String): Boolean {
        return false
    }

    private fun resolveLaunchIntentForPackage(targetPackageName: String): Intent? {
        packageManager.getLaunchIntentForPackage(targetPackageName)?.let { launchIntent ->
            return launchIntent.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

        packageManager.getLeanbackLaunchIntentForPackage(targetPackageName)?.let { launchIntent ->
            return launchIntent.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

        val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
            `package` = targetPackageName
        }

        val launcherMatch = packageManager.queryIntentActivities(
            launcherIntent,
            PackageManager.MATCH_ALL
        ).firstOrNull()

        if (launcherMatch != null) {
            return Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
                setClassName(
                    launcherMatch.activityInfo.packageName,
                    launcherMatch.activityInfo.name
                )
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

        val leanbackIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
            `package` = targetPackageName
        }

        val leanbackMatch = packageManager.queryIntentActivities(
            leanbackIntent,
            PackageManager.MATCH_ALL
        ).firstOrNull()

        if (leanbackMatch != null) {
            return Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
                setClassName(
                    leanbackMatch.activityInfo.packageName,
                    leanbackMatch.activityInfo.name
                )
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

        return null
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

        if (isKioskModeEnabled()) {
            applyHardKioskPolicies()
        } else {
            disableKioskModeSafely()
        }
    }

    private fun isAppUpdatesAllowed(): Boolean {
        return getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
            .getBoolean(allowAppUpdatesKey, false)
    }

    private fun isKioskModeEnabled(): Boolean {
        return getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
            .getBoolean(kioskModeEnabledPrefKey, true)
    }

    private fun getCurrentCustomerRole(): String? {
        return getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
            .getString(currentCustomerRolePrefKey, null)
            ?.trim()
            ?.lowercase()
    }

    private fun isAdminSessionActive(): Boolean {
        return getCurrentCustomerRole() == "admin"
    }

    private fun shouldAllowAppInstalls(): Boolean {
        return !isKioskModeEnabled() || (isAppUpdatesAllowed() && isAdminSessionActive())
    }

    private fun shouldAllowPlayStoreAccess(): Boolean {
        return !isKioskModeEnabled() || isAdminSessionActive()
    }

    private fun syncProtectedAppVisibility() {
        if (!isDeviceOwnerApp()) {
            return
        }

        val dpm = devicePolicyManager ?: return
        val shouldHidePlayStore = !shouldAllowPlayStoreAccess()

        try {
            dpm.setApplicationHidden(adminComponent, playStorePackageName, shouldHidePlayStore)
            Log.d(logTag, "Play Store hidden=$shouldHidePlayStore")
        } catch (error: Exception) {
            Log.w(logTag, "Unable to update Play Store visibility", error)
        }
    }

    private fun hasActiveSessionShortcutTarget(): Boolean {
        if (isAdminSessionActive()) {
            return true
        }

        val expiresAtMs = getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
            .getLong(sessionExpiresAtPrefKey, 0L)

        return expiresAtMs > System.currentTimeMillis()
    }

    private fun isFinalCountdownLaunchLocked(): Boolean {
        if (isAdminSessionActive()) {
            return false
        }

        val expiresAtMs = getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
            .getLong(sessionExpiresAtPrefKey, 0L)

        if (expiresAtMs <= 0L) {
            return false
        }

        val remainingMs = expiresAtMs - System.currentTimeMillis()
        return remainingMs > 0L && remainingMs <= TimeUnit.SECONDS.toMillis(finalCountdownLockSeconds)
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

    private fun allowPackageForAppLaunch(vararg targetPackageNames: String?) {
        if (!isDeviceOwnerApp()) {
            return
        }

        setAllowedLockTaskPackages("com.android.settings", *targetPackageNames)
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
        val targets = LinkedHashSet<String>().apply {
            packageNames
                .map { it.trim() }
                .filter { it.isNotEmpty() && it != this@MainActivity.packageName }
                .forEach(::add)

            val lastLaunchedAppPackage = getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
                .getString(lastLaunchedAppKey, null)
                ?.trim()
            if (!lastLaunchedAppPackage.isNullOrEmpty() &&
                lastLaunchedAppPackage != this@MainActivity.packageName
            ) {
                add(lastLaunchedAppPackage)
            }

            addAll(getActiveBackgroundPackages())
        }

        Log.d(logTag, "Deep freeze reset targets=${targets.joinToString(", ")}")

        val failures = targets.filter { packageName ->
            !forceStopTrackedPackage(packageName)
        }

        getSharedPreferences(policyPrefsName, Context.MODE_PRIVATE)
            .edit()
            .remove(lastLaunchedAppKey)
            .apply()

        return failures
    }

    private fun forceStopTrackedPackage(targetPackageName: String): Boolean {
        if (!isDeviceOwnerApp()) {
            Log.w(logTag, "Cannot force stop app $targetPackageName: Not device owner.")
            return false
        }

        val forceStopped = aggressivelyForceStopPackage(targetPackageName)
        val resetSucceeded = forceStopped
        Log.d(
            logTag,
            "Deep freeze stop package=$targetPackageName forceStopped=$forceStopped " +
                "resetSucceeded=$resetSucceeded"
        )
        return resetSucceeded
    }

    private fun getActiveBackgroundPackages(): Set<String> {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return emptySet()

        return LinkedHashSet<String>().apply {
            activityManager.appTasks.forEach { task ->
                task.taskInfo?.topActivity?.packageName
                    ?.takeIf {
                        it.isNotBlank() &&
                            it != packageName &&
                            it != "com.android.settings"
                    }
                    ?.let(::add)
                task.taskInfo?.baseActivity?.packageName
                    ?.takeIf {
                        it.isNotBlank() &&
                            it != packageName &&
                            it != "com.android.settings"
                    }
                    ?.let(::add)
            }

            activityManager.runningAppProcesses?.forEach { process ->
                process.pkgList?.forEach { processPackage ->
                    if (processPackage.isNotBlank() &&
                        processPackage != packageName &&
                        processPackage != "com.android.settings"
                    ) {
                        add(processPackage)
                    }
                }
            }
        }
    }

    private fun killBackgroundProcess(targetPackageName: String) {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return
        try {
            activityManager.killBackgroundProcesses(targetPackageName)
            Log.d(logTag, "Requested background kill for $targetPackageName")
        } catch (error: Exception) {
            Log.w(logTag, "Unable to kill background process for $targetPackageName", error)
        }
    }

    private fun removeTasksForPackage(targetPackageName: String) {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return

        activityManager.appTasks.forEach { task ->
            val topPackage = task.taskInfo?.topActivity?.packageName
            val basePackage = task.taskInfo?.baseActivity?.packageName
            if (topPackage == targetPackageName || basePackage == targetPackageName) {
                try {
                    task.finishAndRemoveTask()
                    Log.d(logTag, "Removed app task for $targetPackageName")
                } catch (error: Exception) {
                    Log.w(logTag, "Unable to remove app task for $targetPackageName", error)
                }
            }
        }
    }

    private fun aggressivelyForceStopPackage(targetPackageName: String): Boolean {
        removeTasksForPackage(targetPackageName)
        killBackgroundProcess(targetPackageName)
        val firstAttempt = runShellCommand("am force-stop $targetPackageName")
        if (firstAttempt) {
            return true
        }

        Thread.sleep(180L)
        removeTasksForPackage(targetPackageName)
        killBackgroundProcess(targetPackageName)
        val secondAttempt = runShellCommand("am force-stop $targetPackageName")
        Log.d(
            logTag,
            "Aggressive close retry package=$targetPackageName firstAttempt=$firstAttempt secondAttempt=$secondAttempt"
        )
        return secondAttempt
    }

    private fun runShellCommand(command: String): Boolean {
        return try {
            val process = ProcessBuilder("sh", "-c", command)
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            val exited = process.waitFor(15, TimeUnit.SECONDS)
            val exitValue = process.exitValue()
            Log.d(logTag, "Shell command '$command' output: '$output', exited: $exited, exitValue: $exitValue")
            return exited && exitValue == 0
        } catch (e: Exception) {
            Log.e(logTag, "Error running shell command '$command': ${e.message}", e)
            return false
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
