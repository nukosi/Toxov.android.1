package com.toxov.toxov_app

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

// ブロック対象アプリが起動されたときに全画面で表示するブロッカー画面
// singleTaskなので複数積まれることはなく、常に最前面に1枚だけ存在する
class BlockerActivity : Activity() {

    companion object {
        const val EXTRA_BLOCKED_APP = "blocked_app"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ロック画面上にも表示できるようにする
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
        )

        setContentView(buildView())
    }

    // 新しいIntentで再利用された場合（singleTask）も画面は維持する
    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    // 戻るボタンでブロック対象アプリに戻らないようホーム画面へ移動する
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        moveTaskToBack(true)
        val home = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(home)
    }

    private fun buildView(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#0F0F0F"))

            addView(TextView(context).apply {
                text = "🔒"
                textSize = 48f
                gravity = Gravity.CENTER
            })

            addView(TextView(context).apply {
                text = "Toxov"
                textSize = 28f
                setTextColor(Color.WHITE)
                gravity = Gravity.CENTER
                typeface = android.graphics.Typeface.DEFAULT_BOLD
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
}
