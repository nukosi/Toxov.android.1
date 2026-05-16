package com.toxov.toxov_app

import android.Manifest
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val VPN_CHANNEL     = "com.toxov/vpn"
    private val BLOCKER_CHANNEL = "com.toxov/app_blocker"
    private val VPN_REQUEST_CODE = 100

    // VPN許可ダイアログの結果をFlutterに返すために保持しておく
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── VPN チャンネル ──────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepareVpn" -> {
                        val intent = VpnService.prepare(this)
                        if (intent == null) {
                            result.success("already_granted")
                        } else {
                            pendingResult = result
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, VPN_REQUEST_CODE)
                        }
                    }
                    "startVpn" -> {
                        val sites = call.argument<List<String>>("sites") ?: emptyList()
                        val intent = Intent(this, ToxovVpnService::class.java).apply {
                            action = ToxovVpnService.ACTION_START
                            putStringArrayListExtra(ToxovVpnService.EXTRA_DOMAINS, ArrayList(sites))
                        }
                        startForegroundService(intent)
                        result.success(null)
                    }
                    "stopVpn" -> {
                        val intent = Intent(this, ToxovVpnService::class.java).apply {
                            action = ToxovVpnService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "isRunning" -> result.success(ToxovVpnService.isRunning)
                    else -> result.notImplemented()
                }
            }

        // ── アプリブロッカー チャンネル ─────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLOCKER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // PACKAGE_USAGE_STATS権限が付与されているか確認する
                    "hasUsagePermission" -> {
                        result.success(checkUsagePermission())
                    }

                    // 使用状況アクセスの設定画面を開く
                    "requestUsagePermission" -> {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        })
                        result.success(null)
                    }

                    // システムアプリを除くインストール済みアプリ一覧を返す
                    "getInstalledApps" -> {
                        result.success(getInstalledUserApps())
                    }

                    // アプリブロッカーを開始または設定を更新する
                    "startBlocker" -> {
                        val packages   = call.argument<List<String>>("packages") ?: emptyList()
                        val blockStart = call.argument<String>("blockStart") ?: "08:00"
                        val blockEnd   = call.argument<String>("blockEnd")   ?: "21:00"
                        val emergency  = call.argument<Boolean>("emergency")  ?: false
                        val intent = Intent(this, AppBlockerService::class.java).apply {
                            action = AppBlockerService.ACTION_START
                            putStringArrayListExtra(AppBlockerService.EXTRA_PACKAGES, ArrayList(packages))
                            putExtra(AppBlockerService.EXTRA_BLOCK_START, blockStart)
                            putExtra(AppBlockerService.EXTRA_BLOCK_END, blockEnd)
                            putExtra(AppBlockerService.EXTRA_EMERGENCY, emergency)
                        }
                        startForegroundService(intent)
                        result.success(null)
                    }

                    // アプリブロッカーを停止する
                    "stopBlocker" -> {
                        val intent = Intent(this, AppBlockerService::class.java).apply {
                            action = AppBlockerService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }

                    // アプリブロッカーが動作中かどうかを返す
                    "isBlockerRunning" -> result.success(AppBlockerService.isRunning)

                    // SYSTEM_ALERT_WINDOW（フローティング表示）権限が付与されているか確認する
                    "hasOverlayPermission" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }

                    // フローティング表示の設定画面を開く
                    "requestOverlayPermission" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                        startActivity(intent)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // Android 13以降は起動時に通知権限をリクエストする
    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    200
                )
            }
        }
    }

    // VPN許可ダイアログの結果を受け取り、Flutterに返す
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            pendingResult?.success(if (resultCode == RESULT_OK) "granted" else "denied")
            pendingResult = null
        }
    }

    // AppOpsManagerでPACKAGE_USAGE_STATS権限が付与されているか確認する
    private fun checkUsagePermission(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            packageName
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    // ホーム画面（ランチャー）から起動できるアプリを全件取得する
    // FLAG_SYSTEMフィルターではYouTube等のプリインストールアプリが除外されるためこの方式を使う
    private fun getInstalledUserApps(): List<Map<String, String>> {
        val pm = packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN, null).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        @Suppress("DEPRECATION")
        val launchableApps = pm.queryIntentActivities(launcherIntent, 0)
        return launchableApps
            .filter { it.activityInfo.packageName != packageName }
            .map { info ->
                mapOf(
                    "packageName" to info.activityInfo.packageName,
                    "appName"     to info.loadLabel(pm).toString()
                )
            }
            .distinctBy { it["packageName"] }
            .sortedBy { it["appName"] }
    }
}
