package com.toxov.toxov_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.core.app.NotificationCompat
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

// 緊急解除開始から24時間後にAlarmManagerが発火させるレシーバー。
// アプリが閉じていてもブロックを自動再開する。
class EmergencyResumeReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.toxov.ACTION_EMERGENCY_RESUME"
        private const val AGENT_SECRET = "toxov-prod-abc123xyz"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return

        val prefs = context.getSharedPreferences("toxov_boot", Context.MODE_PRIVATE)
        val resumeUrl = prefs.getString("emergency_resume_url", null) ?: return

        // BroadcastReceiverはデフォルト10秒で終了するためgoAsync()で延長する
        val pending = goAsync()
        thread {
            try {
                // サーバーの emergency_unblock フラグをクリアする
                val conn = URL(resumeUrl).openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("X-Toxov-Key", AGENT_SECRET)
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000
                conn.responseCode
                conn.disconnect()
            } catch (_: Exception) {}

            // BootReceiverと同じロジックでVPNを再起動する
            val sitesStr = prefs.getString("vpn_sites", "") ?: ""
            val sites = if (sitesStr.isBlank()) emptyList() else sitesStr.split(",")
            val blockStart = prefs.getString("block_start", "08:00") ?: "08:00"
            val blockEnd = prefs.getString("block_end", "21:00") ?: "21:00"

            if (sites.isNotEmpty() && VpnService.prepare(context) == null) {
                val vpnIntent = Intent(context, ToxovVpnService::class.java).apply {
                    action = ToxovVpnService.ACTION_START
                    putStringArrayListExtra(ToxovVpnService.EXTRA_DOMAINS, ArrayList(sites))
                    putExtra(ToxovVpnService.EXTRA_BLOCK_START, blockStart)
                    putExtra(ToxovVpnService.EXTRA_BLOCK_END, blockEnd)
                    putExtra(ToxovVpnService.EXTRA_EMERGENCY, false)
                }
                context.startForegroundService(vpnIntent)
            }

            showResumeNotification(context)
            pending.finish()
        }
    }

    private fun showResumeNotification(context: Context) {
        val channelId = "toxov_auto_resume"
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(channelId, "Toxov 自動再開",
                    NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentTitle("Toxov")
            .setContentText("緊急解除が24時間を超えたため、ブロックを自動再開しました")
            .setAutoCancel(true)
            .build()
        nm.notify(1002, notification)
    }
}
