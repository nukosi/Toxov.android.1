package com.toxov.toxov_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.core.app.NotificationCompat

// 端末再起動後にアプリブロッカーとVPNを自動復帰させるレシーバー
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val bootAction = intent.action ?: return
        if (bootAction != Intent.ACTION_BOOT_COMPLETED &&
            bootAction != "android.intent.action.QUICKBOOT_POWERON") return  // Samsung対応

        val prefs      = context.getSharedPreferences("toxov_boot", Context.MODE_PRIVATE)
        val pkgStr     = prefs.getString("packages",    "") ?: ""
        val blockStart = prefs.getString("block_start", "08:00") ?: "08:00"
        val blockEnd   = prefs.getString("block_end",   "21:00") ?: "21:00"
        val sitesStr   = prefs.getString("vpn_sites",   "") ?: ""
        val packages   = if (pkgStr.isBlank())   emptyList() else pkgStr.split(",")
        val sites      = if (sitesStr.isBlank()) emptyList() else sitesStr.split(",")

        // アプリブロッカーを再起動する（UsageStats権限があれば即時有効）
        if (packages.isNotEmpty()) {
            val svcIntent = Intent(context, AppBlockerService::class.java).apply {
                action = AppBlockerService.ACTION_START
                putStringArrayListExtra(AppBlockerService.EXTRA_PACKAGES, ArrayList(packages))
                putExtra(AppBlockerService.EXTRA_BLOCK_START, blockStart)
                putExtra(AppBlockerService.EXTRA_BLOCK_END,   blockEnd)
                putExtra(AppBlockerService.EXTRA_EMERGENCY,   false)
            }
            context.startForegroundService(svcIntent)
        }

        // VPN権限が既に許可済みであればサービスを直接起動する。
        // prepare() が null を返す = 許可済み（Activityなしで確認できる）
        if (sites.isNotEmpty() && VpnService.prepare(context) == null) {
            val vpnIntent = Intent(context, ToxovVpnService::class.java).apply {
                action = ToxovVpnService.ACTION_START
                // intentを渡すが、サービス内でSharedPreferencesからも復元するため
                // ここではnullintentとの区別のために明示的に送る
                putStringArrayListExtra(ToxovVpnService.EXTRA_DOMAINS, ArrayList(sites))
                putExtra(ToxovVpnService.EXTRA_BLOCK_START, blockStart)
                putExtra(ToxovVpnService.EXTRA_BLOCK_END,   blockEnd)
                putExtra(ToxovVpnService.EXTRA_EMERGENCY,   false)
            }
            context.startForegroundService(vpnIntent)
        } else if (sites.isNotEmpty()) {
            // VPN権限がまだ付与されていない場合のみ通知でアプリを開くよう促す
            showVpnRebootNotification(context)
        }
    }

    private fun showVpnRebootNotification(context: Context) {
        val channelId = "toxov_reboot"
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(channelId, "Toxov 再起動通知",
                    NotificationManager.IMPORTANCE_DEFAULT)
            )
        }

        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
        val pi = PendingIntent.getActivity(
            context, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentTitle("Toxov")
            .setContentText("タップしてサイトブロックを再開してください")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()

        nm.notify(1001, notification)
    }
}
