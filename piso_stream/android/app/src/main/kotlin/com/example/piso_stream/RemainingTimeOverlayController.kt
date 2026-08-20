package com.example.piso_stream

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

object RemainingTimeOverlayController {
    private const val logTag = "PisoStreamOverlay"
    private val handler = Handler(Looper.getMainLooper())

    private var windowManager: WindowManager? = null
    private var overlayView: LinearLayout? = null
    private var timeTextView: TextView? = null
    private var countdownExpiresAtMs: Long = 0L
    private var initialDisplayRemainingMs: Long = 0L
    private var countdownMultiplier: Double = 1.0
    private var countdownStartedAtMs: Long = 0L
    private var staticLabel: String? = null
    private var updateRunnable: Runnable? = null
    private var showRequestVersion: Int = 0

    fun showCountdown(context: Context, displayRemainingMs: Long, multiplier: Double) {
        val appContext = context.applicationContext
        val requestVersion = ++showRequestVersion
        initialDisplayRemainingMs = displayRemainingMs.coerceAtLeast(0L)
        countdownMultiplier = multiplier.coerceAtLeast(1.0)
        countdownStartedAtMs = System.currentTimeMillis()
        countdownExpiresAtMs =
            countdownStartedAtMs + (initialDisplayRemainingMs / countdownMultiplier).toLong()
        staticLabel = null

        if (!Settings.canDrawOverlays(appContext)) {
            Log.d(logTag, "Overlay permission not granted; remaining time overlay skipped")
            hide()
            return
        }

        handler.post {
            if (requestVersion != showRequestVersion) {
                return@post
            }
            ensureOverlayView(appContext)
            val view = overlayView ?: return@post
            val manager = windowManager ?: return@post

            if (!attachOverlayView(view, manager)) {
                return@post
            }

            updateOverlayText()
            scheduleUpdates(appContext)
        }
    }

    fun showLabel(context: Context, label: String) {
        val appContext = context.applicationContext
        val requestVersion = ++showRequestVersion
        countdownExpiresAtMs = 0L
        staticLabel = label

        if (!Settings.canDrawOverlays(appContext)) {
            Log.d(logTag, "Overlay permission not granted; open-time overlay skipped")
            hide()
            return
        }

        handler.post {
            if (requestVersion != showRequestVersion) {
                return@post
            }
            ensureOverlayView(appContext)
            val view = overlayView ?: return@post
            val manager = windowManager ?: return@post

            if (!attachOverlayView(view, manager)) {
                return@post
            }

            updateOverlayText()
            scheduleUpdates(appContext)
        }
    }

    fun hide() {
        showRequestVersion++
        handler.post {
            updateRunnable?.let(handler::removeCallbacks)
            updateRunnable = null

            val view = overlayView ?: return@post
            val manager = windowManager ?: return@post
            if (view.parent != null) {
                try {
                    manager.removeViewImmediate(view)
                } catch (error: Exception) {
                    Log.w(logTag, "Unable to remove remaining time overlay", error)
                }
            }
        }
    }

    private fun attachOverlayView(view: LinearLayout, manager: WindowManager): Boolean {
        removeExistingOverlay(manager, view)

        if (view.parent == null) {
            try {
                manager.addView(view, buildLayoutParams())
                Log.d(logTag, "Remaining time overlay added")
            } catch (error: Exception) {
                Log.w(logTag, "Unable to add remaining time overlay", error)
                return false
            }
        }
        return true
    }

    private fun removeExistingOverlay(manager: WindowManager, view: LinearLayout) {
        if (view.parent == null) {
            return
        }

        try {
            manager.removeViewImmediate(view)
        } catch (error: Exception) {
            Log.w(logTag, "Unable to replace existing overlay view", error)
        }
    }

    private fun ensureOverlayView(context: Context) {
        if (overlayView != null && windowManager != null) {
            return
        }

        windowManager = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        val timeLabel = TextView(context).apply {
            setTextColor(Color.parseColor("#79FFE1"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER
            minWidth = dp(context, 54)
            setPadding(dp(context, 8), 0, dp(context, 8), 0)
        }
        timeTextView = timeLabel

        overlayView = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(context, 7), dp(context, 5), dp(context, 7), dp(context, 5))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(context, 15).toFloat()
                setColor(Color.argb(186, 0, 0, 0))
                setStroke(dp(context, 1), Color.argb(90, 121, 255, 225))
            }
            addView(buildVolumeButton(context) { showSystemVolumeSlider(context) })
            addView(timeLabel)
        }
    }

    private fun buildLayoutParams(): WindowManager.LayoutParams {
        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0
            y = 28
        }
    }

    private fun scheduleUpdates(context: Context) {
        updateRunnable?.let(handler::removeCallbacks)
        updateRunnable = Runnable {
            if (!Settings.canDrawOverlays(context)) {
                hide()
                return@Runnable
            }

            if (staticLabel == null && countdownExpiresAtMs <= System.currentTimeMillis()) {
                hide()
                return@Runnable
            }

            updateOverlayText()
            updateRunnable?.let {
                handler.postDelayed(it, 250L)
            }
        }
        updateRunnable?.let {
            handler.postDelayed(it, 250L)
        }
    }

    private fun updateOverlayText() {
        timeTextView?.text = staticLabel ?: run {
            val elapsedMs = (System.currentTimeMillis() - countdownStartedAtMs).coerceAtLeast(0L)
            val consumedMs = (elapsedMs * countdownMultiplier).toLong()
            val remainingMs = (initialDisplayRemainingMs - consumedMs).coerceAtLeast(0L)
            formatRemaining(remainingMs)
        }
    }

    private fun buildVolumeButton(
        context: Context,
        onClick: () -> Unit
    ): TextView {
        return TextView(context).apply {
            text = "VOL"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER
            minWidth = dp(context, 34)
            minHeight = dp(context, 28)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(85, 255, 255, 255))
            }
            setOnClickListener { onClick() }
        }
    }

    private fun showSystemVolumeSlider(context: Context) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        audioManager.adjustStreamVolume(
            AudioManager.STREAM_MUSIC,
            AudioManager.ADJUST_SAME,
            AudioManager.FLAG_SHOW_UI
        )
    }

    private fun formatRemaining(remainingMs: Long): String {
        val totalSeconds = if (remainingMs <= 0L) {
            0L
        } else {
            ((remainingMs + 999L) / 1000L).coerceAtLeast(0L)
        }
        val hours = totalSeconds / 3600L
        val minutes = (totalSeconds % 3600L) / 60L
        val seconds = totalSeconds % 60L

        return if (hours > 0L) {
            "%02d:%02d:%02d".format(hours, minutes, seconds)
        } else {
            "%02d:%02d".format(minutes, seconds)
        }
    }

    private fun dp(context: Context, value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            context.resources.displayMetrics
        ).toInt()
    }
}
