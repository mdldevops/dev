package com.example.piso_stream

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.BatteryManager
import android.util.Base64
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL

class ChargingMonitorReceiver : BroadcastReceiver() {
    companion object {
        private const val logTag = "PisoStreamCharge"
        private const val actionRun = "com.example.piso_stream.action.RUN_CHARGING_MONITOR"
        private const val requestCode = 4201
        private const val flutterPrefsName = "FlutterSharedPreferences"
        private const val nativePrefsName = "charging_monitor_prefs"
        private const val intervalMs = 60_000L
        private const val evaluateDelayMs = 250L

        private const val chargingControlEnabledKey = "flutter.charging_control_enabled"
        private const val chargerControlModeKey = "flutter.charger_control_mode"
        private const val chargerStartPercentKey = "flutter.charger_start_percent"
        private const val chargerStopPercentKey = "flutter.charger_stop_percent"
        private const val shellyChargeOnUrlKey = "flutter.shelly_charge_on_url"
        private const val shellyChargeOffUrlKey = "flutter.shelly_charge_off_url"
        private const val shellyUseToggleKey = "flutter.shelly_use_toggle"
        private const val shellyToggleUrlKey = "flutter.shelly_toggle_url"
        private const val shellyUseAuthKey = "flutter.shelly_use_auth"
        private const val shellyUsernameKey = "flutter.shelly_username"
        private const val shellyPasswordKey = "flutter.shelly_password"

        private const val chargerControlModeShelly = "shelly"
        private const val relayStateKnownKey = "relay_state_known"
        private const val relayEnabledKey = "relay_enabled"

        fun scheduleNext(context: Context, delayMs: Long = intervalMs) {
            val alarmManager = context.getSystemService(AlarmManager::class.java) ?: return
            val pendingIntent = buildPendingIntent(context)
            val triggerAt = System.currentTimeMillis() + delayMs.coerceAtLeast(1_000L)
            try {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pendingIntent
                )
            } catch (error: SecurityException) {
                Log.w(logTag, "Exact alarm not allowed yet, falling back for charging monitor", error)
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pendingIntent
                )
            } catch (error: Exception) {
                Log.w(logTag, "Unable to schedule charging monitor alarm", error)
            }
        }

        fun triggerRefresh(context: Context, resetDecisionCache: Boolean) {
            val appContext = context.applicationContext
            ChargingMonitorService.start(appContext)
            if (resetDecisionCache) {
                appContext.getSharedPreferences(nativePrefsName, Context.MODE_PRIVATE)
                    .edit()
                    .remove(relayStateKnownKey)
                    .remove(relayEnabledKey)
                    .apply()
            }
            Thread {
                try {
                    ChargingMonitorReceiver().evaluateCharging(appContext)
                } catch (error: Exception) {
                    Log.w(logTag, "Immediate charging monitor refresh failed", error)
                } finally {
                    scheduleNext(appContext, intervalMs)
                }
            }.start()
        }

        fun evaluateNow(context: Context): Map<String, Any?> {
            return ChargingMonitorReceiver().evaluateCharging(context.applicationContext)
        }

        private fun buildPendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, ChargingMonitorReceiver::class.java).apply {
                action = actionRun
            }
            return PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != actionRun) {
            return
        }

        val pendingResult = goAsync()
        Thread {
            try {
                evaluateCharging(context)
            } catch (error: Exception) {
                Log.w(logTag, "Charging monitor evaluation failed", error)
            } finally {
                scheduleNext(context)
                pendingResult.finish()
            }
        }.start()
    }

    private fun evaluateCharging(context: Context): Map<String, Any?> {
        val flutterPrefs = context.getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
        val chargingControlEnabled = flutterPrefs.getBoolean(chargingControlEnabledKey, true)
        if (!chargingControlEnabled) {
            Log.d(logTag, "Charging monitor skipped: charging control disabled")
            return result("skipped_disabled")
        }

        val mode = flutterPrefs.getString(chargerControlModeKey, "ble")
            ?.trim()
            ?.lowercase()
            ?: "ble"

        if (mode != chargerControlModeShelly) {
            Log.d(logTag, "Charging monitor skipped: mode=$mode")
            return result("skipped_mode", mode = mode)
        }

        val startPercent = getIntPreference(context, chargerStartPercentKey, 20)
        val stopPercent = getIntPreference(context, chargerStopPercentKey, 80)
        if (startPercent >= stopPercent) {
            Log.w(logTag, "Charging monitor skipped: invalid thresholds start=$startPercent stop=$stopPercent")
            return result("skipped_invalid_thresholds", startPercent = startPercent, stopPercent = stopPercent)
        }

        val batteryLevel = getBatteryLevel(context)
        if (batteryLevel !in 0..100) {
            Log.w(logTag, "Charging monitor skipped: invalid battery level=$batteryLevel")
            return result("skipped_invalid_battery", batteryLevel = batteryLevel, startPercent = startPercent, stopPercent = stopPercent)
        }

        val useToggle = flutterPrefs.getBoolean(shellyUseToggleKey, false)
        val onUrl = flutterPrefs.getString(shellyChargeOnUrlKey, "")?.trim().orEmpty()
        val offUrl = flutterPrefs.getString(shellyChargeOffUrlKey, "")?.trim().orEmpty()
        val toggleUrl = flutterPrefs.getString(shellyToggleUrlKey, "")?.trim().orEmpty()
        if (useToggle && toggleUrl.isEmpty()) {
            Log.w(logTag, "Charging monitor skipped: Shelly toggle URL missing")
            return result("skipped_missing_toggle_url", batteryLevel = batteryLevel, startPercent = startPercent, stopPercent = stopPercent)
        }
        if (!useToggle && (onUrl.isEmpty() || offUrl.isEmpty())) {
            Log.w(logTag, "Charging monitor skipped: Shelly URLs missing")
            return result("skipped_missing_urls", batteryLevel = batteryLevel, startPercent = startPercent, stopPercent = stopPercent)
        }

        val useAuth = flutterPrefs.getBoolean(shellyUseAuthKey, false)
        val username = flutterPrefs.getString(shellyUsernameKey, "") ?: ""
        val password = flutterPrefs.getString(shellyPasswordKey, "") ?: ""

        val nativePrefs = context.getSharedPreferences(nativePrefsName, Context.MODE_PRIVATE)
        val hasRelayState = nativePrefs.getBoolean(relayStateKnownKey, false)
        val lastRelayEnabled = nativePrefs.getBoolean(relayEnabledKey, false)
        val desiredRelayEnabled = when {
            batteryLevel <= startPercent -> true
            batteryLevel >= stopPercent -> false
            else -> null
        }
        if (desiredRelayEnabled == null) {
            Log.d(logTag, "Charging monitor no command battery=$batteryLevel start=$startPercent stop=$stopPercent")
            return result("no_command_between_thresholds", batteryLevel = batteryLevel, startPercent = startPercent, stopPercent = stopPercent)
        }

        if (useToggle) {
            val currentRelayEnabled = readShellyRelayState(
                statusUrlFromShellyCommand(toggleUrl),
                useAuth,
                username,
                password
            )

            if (currentRelayEnabled != null) {
                nativePrefs.edit()
                    .putBoolean(relayStateKnownKey, true)
                    .putBoolean(relayEnabledKey, currentRelayEnabled)
                    .apply()

                if (currentRelayEnabled == desiredRelayEnabled) {
                    Log.d(
                        logTag,
                        "Charging monitor no-op battery=$batteryLevel actualRelay=$currentRelayEnabled target=$desiredRelayEnabled"
                    )
                    return result("no_op_actual_matches", batteryLevel = batteryLevel, startPercent = startPercent, stopPercent = stopPercent, shouldEnable = desiredRelayEnabled)
                }
            } else if (hasRelayState && desiredRelayEnabled == lastRelayEnabled) {
                Log.d(logTag, "Charging monitor no-op battery=$batteryLevel shouldEnable=$desiredRelayEnabled")
                return result("no_op_cached_matches", batteryLevel = batteryLevel, startPercent = startPercent, stopPercent = stopPercent, shouldEnable = desiredRelayEnabled)
            }
        }

        val targetUrl = if (useToggle) {
            toggleUrl
        } else if (desiredRelayEnabled) {
            onUrl
        } else {
            offUrl
        }
        val responseCode = sendShellyCommand(
            targetUrl = targetUrl,
            useAuth = useAuth,
            username = username,
            password = password
        )
        Log.d(
            logTag,
            "Charging monitor requested ${if (desiredRelayEnabled) "ON" else "OFF"} url=$targetUrl battery=$batteryLevel responseCode=$responseCode"
        )

        if (responseCode in 200..299) {
            nativePrefs.edit()
                .putBoolean(relayStateKnownKey, true)
                .putBoolean(relayEnabledKey, desiredRelayEnabled)
                .apply()
            Log.d(
                logTag,
                "Charging monitor command sent battery=$batteryLevel shouldEnable=$desiredRelayEnabled responseCode=$responseCode"
            )
            return result(
                if (desiredRelayEnabled) "sent_on" else "sent_off",
                batteryLevel = batteryLevel,
                startPercent = startPercent,
                stopPercent = stopPercent,
                shouldEnable = desiredRelayEnabled,
                responseCode = responseCode
            )
        } else {
            Log.w(
                logTag,
                "Charging monitor command failed battery=$batteryLevel shouldEnable=$desiredRelayEnabled responseCode=$responseCode"
            )
            return result(
                "command_failed",
                batteryLevel = batteryLevel,
                startPercent = startPercent,
                stopPercent = stopPercent,
                shouldEnable = desiredRelayEnabled,
                responseCode = responseCode
            )
        }
    }

    private fun result(
        status: String,
        mode: String? = null,
        batteryLevel: Int? = null,
        startPercent: Int? = null,
        stopPercent: Int? = null,
        shouldEnable: Boolean? = null,
        responseCode: Int? = null
    ): Map<String, Any?> {
        return mapOf(
            "status" to status,
            "mode" to mode,
            "batteryLevel" to batteryLevel,
            "startPercent" to startPercent,
            "stopPercent" to stopPercent,
            "shouldEnable" to shouldEnable,
            "responseCode" to responseCode
        )
    }

    private fun statusUrlFromShellyCommand(commandUrl: String): String {
        return try {
            val url = URL(commandUrl)
            URL(url.protocol, url.host, url.port, url.path).toString()
        } catch (_: Exception) {
            commandUrl.substringBefore("?")
        }
    }

    private fun getIntPreference(context: Context, key: String, defaultValue: Int): Int {
        val prefs = context.getSharedPreferences(flutterPrefsName, Context.MODE_PRIVATE)
        return when (val value = prefs.all[key]) {
            is Int -> value
            is Long -> value.toInt()
            is Float -> value.toInt()
            is Double -> value.toInt()
            is String -> value.toIntOrNull() ?: defaultValue
            else -> defaultValue
        }
    }

    private fun getBatteryLevel(context: Context): Int {
        val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        return batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
    }

    private fun readShellyRelayState(
        statusUrl: String,
        useAuth: Boolean,
        username: String,
        password: String
    ): Boolean? {
        val connection = (URL(statusUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8_000
            readTimeout = 8_000
            useCaches = false
            if (useAuth) {
                val credentials = "$username:$password"
                val encoded = Base64.encodeToString(credentials.toByteArray(), Base64.NO_WRAP)
                setRequestProperty("Authorization", "Basic $encoded")
            }
        }

        return try {
            connection.connect()
            if (connection.responseCode !in 200..299) {
                return null
            }
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            Regex("\"ison\"\\s*:\\s*(true|false)")
                .find(body)
                ?.groupValues
                ?.getOrNull(1)
                ?.let { it == "true" }
        } catch (error: Exception) {
            Log.w(logTag, "Unable to read Shelly relay state from $statusUrl", error)
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun sendShellyCommand(
        targetUrl: String,
        useAuth: Boolean,
        username: String,
        password: String
    ): Int {
        val connection = (URL(targetUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8_000
            readTimeout = 8_000
            useCaches = false
            if (useAuth) {
                val credentials = "$username:$password"
                val encoded = Base64.encodeToString(credentials.toByteArray(), Base64.NO_WRAP)
                setRequestProperty("Authorization", "Basic $encoded")
            }
        }

        return try {
            connection.connect()
            connection.responseCode
        } finally {
            connection.disconnect()
        }
    }
}
