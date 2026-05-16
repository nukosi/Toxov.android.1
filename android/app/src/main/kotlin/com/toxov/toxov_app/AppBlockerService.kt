package com.toxov.toxov_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

// UsageStatsManagerで1秒ごとにフォアグラウンドアプリを監視し、
// ブロック対象アプリが検出されたらSYSTEM_ALERT_WINDOWオーバーレイで操作不能にする
class AppBlockerService : Service() {

    companion object {
        const val ACTION_START      = "com.toxov.APP_BLOCKER_START"
        const val ACTION_STOP       = "com.toxov.APP_BLOCKER_STOP"
        const val EXTRA_PACKAGES    = "packages"
        const val EXTRA_BLOCK_START = "blockStart"
        const val EXTRA_BLOCK_END   = "blockEnd"
        const val EXTRA_EMERGENCY   = "emergency"

        @Volatile var isRunning = false
    }

    private var running         = false
    private var blockedPackages : Set<String> = emptySet()
    private var blockStartMin   = 0
    private var blockEndMin     = 0
    private var emergency       = false
    private var lastBlockedPkg  : String? = null
    private var overlayView     : View? = null
    private val mainHandler     = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?) = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val pkgs  = intent.getStringArrayListExtra(EXTRA_PACKAGES) ?: emptyList()
                val start = intent.getStringExtra(EXTRA_BLOCK_START) ?: "08:00"
                val end   = intent.getStringExtra(EXTRA_BLOCK_END)   ?: "21:00"
                val emerg = intent.getBooleanExtra(EXTRA_EMERGENCY, false)
                blockedPackages = pkgs.map { it.lowercase() }.toSet()
                blockStartMin   = parseTime(start)
                blockEndMin     = parseTime(end)
                emergency       = emerg
                if (!running) startMonitor()
            }
            ACTION_STOP -> stopMonitor()
        }
        return START_STICKY
    }

    private fun startMonitor() {
        running   = true
        isRunning = true
        startForeground(2, buildForegroundNotification())
        Thread {
            while (running) {
                try { checkForeground() } catch (_: Exception) {}
                Thread.sleep(1000)
            }
        }.start()
    }

    private fun stopMonitor() {
        running   = false
        isRunning = false
        mainHandler.post { hideOverlay() }
        stopForeground(true)
        stopSelf()
    }

    private fun checkForeground() {
        if (emergency || !isInBlockTime()) {
            if (lastBlockedPkg != null) {
                mainHandler.post { hideOverlay() }
                lastBlockedPkg = null
            }
            return
        }

        val fg = getForegroundApp() ?: return

        // Toxov自身が前面のときはオーバーレイを消す
        if (fg == packageName) {
            mainHandler.post { hideOverlay() }
            lastBlockedPkg = null
            return
        }

        if (blockedPackages.contains(fg.lowercase())) {
            mainHandler.post { showOverlay() }
            lastBlockedPkg = fg
        } else {
            if (lastBlockedPkg != null) {
                mainHandler.post { hideOverlay() }
                lastBlockedPkg = null
            }
        }
    }

    // SYSTEM_ALERT_WINDOWオーバーレイを表示してアプリを操作不能にする
    private fun showOverlay() {
        if (overlayView != null) return
        if (!Settings.canDrawOverlays(this)) return  // 権限なしなら何もしない

        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // FLAG_NOT_FOCUSABLEを設定しないことでキー・タッチ入力を両方奪う
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            PixelFormat.OPAQUE
        )
        val view = buildOverlayView()
        wm.addView(view, params)
        overlayView = view
    }

    private fun hideOverlay() {
        val v = overlayView ?: return
        try {
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(v)
        } catch (_: Exception) {}
        overlayView = null
    }

    private fun buildOverlayView(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity     = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0F0F0F"))

            // タッチイベントを全て消費してブロック対象アプリに届かないようにする
            setOnTouchListener { _, _ -> true }

            addView(TextView(context).apply {
                text     = "🔒"
                textSize = 52f
                gravity  = Gravity.CENTER
            })
            addView(TextView(context).apply {
                text      = "Toxov"
                textSize  = 30f
                setTextColor(Color.WHITE)
                gravity   = Gravity.CENTER
                typeface  = android.graphics.Typeface.DEFAULT_BOLD
                setPadding(0, 32, 0, 0)
            })
            addView(TextView(context).apply {
                text = "ブロック中"
                textSize = 16f
                setTextColor(Color.parseColor("#888888"))
                gravity = Gravity.CENTER
                setPadding(0, 8, 0, 0)
            })
            addView(TextView(context).apply {
                text = "このアプリはブロック時間帯に使用できません"
                textSize = 13f
                setTextColor(Color.parseColor("#555555"))
                gravity = Gravity.CENTER
                setPadding(48, 32, 48, 0)
            })
        }
    }

    private fun getForegroundApp(): String? {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val stats = usm.queryUsageStats(
            UsageStatsManager.INTERVAL_DAILY, now - 10_000, now
        ) ?: return null
        return stats.filter { it.lastTimeUsed > 0 }
                    .maxByOrNull { it.lastTimeUsed }?.packageName
    }

    private fun isInBlockTime(): Boolean {
        val cal    = java.util.Calendar.getInstance()
        val nowMin = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 +
                     cal.get(java.util.Calendar.MINUTE)
        return nowMin >= blockStartMin && nowMin < blockEndMin
    }

    private fun parseTime(t: String): Int {
        val p = t.split(":")
        return (p[0].toIntOrNull() ?: 0) * 60 + (p[1].toIntOrNull() ?: 0)
    }

    private fun buildForegroundNotification(): Notification {
        val channelId = "toxov_app_blocker"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(channelId, "Toxov アプリブロック", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
        return Notification.Builder(this, channelId)
            .setContentTitle("Toxov")
            .setContentText("アプリブロック監視中")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .build()
    }

    override fun onDestroy() {
        mainHandler.post { hideOverlay() }
        stopMonitor()
        super.onDestroy()
    }
}
