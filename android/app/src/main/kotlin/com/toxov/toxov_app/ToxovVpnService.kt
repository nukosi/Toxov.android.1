package com.toxov.toxov_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer

// AndroidのVpnService APIを使ってローカルVPNトンネルを張り、
// DNS（UDP:53）クエリを傍受してブロック対象ドメインへの応答を 0.0.0.0 に書き換える。
// AppBlockerServiceと同様のスケジュールループを持ち、
// アプリが閉じていてもブロック時間帯に自律的にVPNを開始・終了する。
class ToxovVpnService : VpnService() {

    companion object {
        const val ACTION_START      = "com.toxov.ACTION_START"
        const val ACTION_STOP       = "com.toxov.ACTION_STOP"
        const val EXTRA_DOMAINS     = "domains"
        const val EXTRA_BLOCK_START = "blockStart"
        const val EXTRA_BLOCK_END   = "blockEnd"
        const val EXTRA_EMERGENCY   = "emergency"

        // FlutterのMethodChannelおよびToxovAccessibilityServiceから参照するためstaticに持つ
        @Volatile var isRunning      = false
        @Volatile var blockedDomains: Set<String> = emptySet()
    }

    private var tunnel: ParcelFileDescriptor? = null
    private var serviceActive = false
    private var blockStartMin = 0
    private var blockEndMin   = 0
    @Volatile private var emergency = false
    private val upstreamDns: InetAddress = InetAddress.getByName("8.8.8.8")

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKYでシステム再起動後にintentがnullで呼ばれた場合はSharedPreferencesから復元する
        val prefs = getSharedPreferences("toxov_boot", Context.MODE_PRIVATE)
        val action = intent?.action ?: ACTION_START

        when (action) {
            ACTION_START -> {
                val sitesStr = intent?.getStringArrayListExtra(EXTRA_DOMAINS)?.joinToString(",")
                    ?: prefs.getString("vpn_sites", "") ?: ""
                val start = intent?.getStringExtra(EXTRA_BLOCK_START)
                    ?: prefs.getString("block_start", "08:00") ?: "08:00"
                val end = intent?.getStringExtra(EXTRA_BLOCK_END)
                    ?: prefs.getString("block_end", "21:00") ?: "21:00"
                val emerg = intent?.getBooleanExtra(EXTRA_EMERGENCY, false) ?: false

                val domains = if (sitesStr.isBlank()) emptyList() else sitesStr.split(",")
                blockedDomains = domains.map { it.lowercase() }.toSet()
                blockStartMin  = parseTime(start)
                blockEndMin    = parseTime(end)
                emergency      = emerg

                // intentがある（Flutter呼び出し）場合だけSharedPreferencesを更新する
                if (intent != null) {
                    prefs.edit()
                        .putString("vpn_sites",   sitesStr)
                        .putString("block_start", start)
                        .putString("block_end",   end)
                        .apply()
                }

                if (!serviceActive) {
                    serviceActive = true
                    startForeground(1, buildNotification())
                    // スケジュールループを別スレッドで起動する（メインスレッドをブロックしない）
                    Thread { scheduleLoop() }.start()
                }

                // 緊急解除時はトンネルを即座に切る（次の30秒サイクルを待たない）
                if (emergency) closeTunnel()
                updateNotification()
            }
            ACTION_STOP -> stopAll()
        }
        return START_STICKY
    }

    // ブロック時間帯かどうかを30秒ごとに確認し、VPNトンネルを開閉する。
    // AppBlockerServiceと同じパターンで常駐することで、アプリを開かなくてもブロックが機能する。
    private fun scheduleLoop() {
        while (serviceActive) {
            val shouldBlock = !emergency && isInBlockTime()
            if (shouldBlock && tunnel == null) {
                openTunnel()
            } else if (!shouldBlock && tunnel != null) {
                closeTunnel()
            }
            updateNotification()
            Thread.sleep(30_000)
        }
    }

    private fun openTunnel() {
        val builder = Builder()
            .setSession("Toxov")
            .addAddress("10.233.0.1", 24)
            // DNSトラフィックだけVPN経由にする（他のHTTPS等はそのままインターネットへ）
            .addDnsServer("10.233.0.2")    // 仮想DNSサーバーアドレス
            .addRoute("10.233.0.2", 32)    // 仮想DNSへのルートのみVPN経由
            // TikTokなど一部アプリはシステムDNSを無視して主要DNSサーバーに直接クエリを送る
            // それらのIPもVPN経由にすることで、ポート53 UDPは傍受・ポート443（DoH）は遮断する
            // forwardDns内でprotect()済みのソケットを使うため8.8.8.8へのループは起きない
            .addRoute("8.8.8.8", 32)           // Google DNS
            .addRoute("8.8.4.4", 32)           // Google DNS
            .addRoute("1.1.1.1", 32)           // Cloudflare DNS
            .addRoute("1.0.0.1", 32)           // Cloudflare DNS
            .addRoute("9.9.9.9", 32)           // Quad9
            .addRoute("149.112.112.112", 32)   // Quad9
            .setMtu(1500)
            .setBlocking(true)
        val fd = builder.establish() ?: return  // VPN権限がなければnullを返す
        tunnel    = fd
        isRunning = true
        // パケット処理はメインスレッドをブロックしないようにスレッドで回す
        Thread { runLoop(fd) }.start()
    }

    private fun closeTunnel() {
        tunnel?.close()
        tunnel    = null
        isRunning = false
    }

    private fun stopAll() {
        serviceActive = false
        closeTunnel()
        blockedDomains = emptySet()
        stopForeground(true)
        stopSelf()
    }

    // fdが close されると read() が IOException を投げてループを抜ける
    private fun runLoop(fd: ParcelFileDescriptor) {
        val input  = FileInputStream(fd.fileDescriptor)
        val output = FileOutputStream(fd.fileDescriptor)
        val buf    = ByteArray(32767)
        try {
            while (true) {
                val len = input.read(buf)
                if (len <= 0) continue
                val response = processPacket(buf.copyOf(len))
                if (response != null) output.write(response)
            }
        } catch (_: Exception) {
            // fd が閉じられたら正常終了
        }
    }

    // IPパケットを解析してDNSクエリだけ処理する。それ以外は無視（nullを返す）
    private fun processPacket(packet: ByteArray): ByteArray? {
        if (packet.size < 20) return null

        val ipVersion = (packet[0].toInt() and 0xFF) shr 4
        if (ipVersion != 4) return null  // IPv4のみ対応

        val ihl      = (packet[0].toInt() and 0x0F) * 4
        val protocol = packet[9].toInt() and 0xFF
        if (protocol != 17) return null  // UDP(17)以外は無視
        if (packet.size < ihl + 8) return null

        val dstPort = ((packet[ihl + 2].toInt() and 0xFF) shl 8) or
                       (packet[ihl + 3].toInt() and 0xFF)
        if (dstPort != 53) return null  // DNS(53)以外は無視

        val dnsPayload = packet.copyOfRange(ihl + 8, packet.size)
        if (dnsPayload.size < 13) return null

        val domain = extractDomain(dnsPayload)
        return if (domain != null && isBlocked(domain)) {
            buildBlockResponse(packet, ihl, dnsPayload)
        } else {
            forwardDns(packet, ihl)
        }
    }

    // DNSクエリペイロードからドメイン名を取り出す
    private fun extractDomain(dns: ByteArray): String? {
        val sb = StringBuilder()
        var i = 12  // DNSヘッダー(12バイト)の後から読む
        while (i < dns.size) {
            val len = dns[i].toInt() and 0xFF
            if (len == 0) break
            if (sb.isNotEmpty()) sb.append('.')
            if (i + 1 + len > dns.size) return null
            sb.append(String(dns, i + 1, len))
            i += len + 1
        }
        return sb.toString().lowercase().ifEmpty { null }
    }

    // ブロック対象かどうかをチェック（サブドメインも含む）
    private fun isBlocked(domain: String): Boolean =
        blockedDomains.any { domain == it || domain.endsWith(".$it") }

    // ブロック応答：0.0.0.0 を返すDNS Aレコードを組み立ててIPパケットとして返す
    private fun buildBlockResponse(packet: ByteArray, ihl: Int, dnsQuery: ByteArray): ByteArray {
        val dnsResponse = buildDnsBlockResponse(dnsQuery)
        return buildIpUdpPacket(packet, ihl, dnsResponse)
    }

    // 0.0.0.0 を返すDNSレスポンスパケットを組み立てる
    private fun buildDnsBlockResponse(query: ByteArray): ByteArray {
        // クエスチョンセクションの末尾(null終端 + type + class)を探す
        var i = 12
        while (i < query.size && query[i].toInt() != 0) {
            i += (query[i].toInt() and 0xFF) + 1
        }
        i += 5  // null(1) + type(2) + class(2)
        val questionSection = query.copyOfRange(12, i)

        val buf = ByteBuffer.allocate(12 + questionSection.size + 16)

        // DNSヘッダー
        buf.put(query[0]); buf.put(query[1])  // クエリと同じID
        buf.putShort(0x8180.toShort())         // QR=1, RD=1, RA=1
        buf.putShort(1)                         // QDCount=1
        buf.putShort(1)                         // ANCount=1
        buf.putShort(0); buf.putShort(0)        // NS/AR=0

        // クエスチョンセクション（そのままコピー）
        buf.put(questionSection)

        // アンサーセクション：0.0.0.0 のAレコード
        buf.putShort(0xC00C.toShort())  // name: クエスチョンへのポインタ
        buf.putShort(1)                  // type: A
        buf.putShort(1)                  // class: IN
        buf.putInt(5)                    // TTL: 5秒
        buf.putShort(4)                  // RDLENGTH: 4バイト
        buf.put(byteArrayOf(0, 0, 0, 0)) // 0.0.0.0

        return buf.array()
    }

    // DNSクエリをそのまま8.8.8.8に転送して応答を返す
    private fun forwardDns(packet: ByteArray, ihl: Int): ByteArray? {
        val dnsPayload = packet.copyOfRange(ihl + 8, packet.size)
        return try {
            val socket = DatagramSocket()
            protect(socket)  // VPNを迂回して実際のネットワークに出る
            socket.soTimeout = 3000
            socket.send(DatagramPacket(dnsPayload, dnsPayload.size, upstreamDns, 53))
            val recvBuf = ByteArray(4096)
            val recvPacket = DatagramPacket(recvBuf, recvBuf.size)
            socket.receive(recvPacket)
            socket.close()
            buildIpUdpPacket(packet, ihl, recvBuf.copyOf(recvPacket.length))
        } catch (e: Exception) {
            null
        }
    }

    // 送受信IPを入れ替えてUDP+DNSペイロードをラップしたIPパケットを組み立てる
    private fun buildIpUdpPacket(original: ByteArray, ihl: Int, dnsPayload: ByteArray): ByteArray {
        val udpLen   = 8 + dnsPayload.size
        val totalLen = ihl + udpLen
        val pkt      = ByteArray(totalLen)

        // IPヘッダーをコピーして送受信IPを入れ替える
        System.arraycopy(original, 0, pkt, 0, ihl)
        System.arraycopy(original, 16, pkt, 12, 4)  // dst→src
        System.arraycopy(original, 12, pkt, 16, 4)  // src→dst
        pkt[2] = (totalLen shr 8).toByte()
        pkt[3] = (totalLen and 0xFF).toByte()
        pkt[10] = 0; pkt[11] = 0
        val cksum = ipChecksum(pkt, 0, ihl)
        pkt[10] = (cksum shr 8).toByte(); pkt[11] = (cksum and 0xFF).toByte()

        // UDPヘッダー（送受信ポートを入れ替える）
        pkt[ihl]     = original[ihl + 2]; pkt[ihl + 1] = original[ihl + 3]  // dst port → src
        pkt[ihl + 2] = original[ihl];     pkt[ihl + 3] = original[ihl + 1]  // src port → dst
        pkt[ihl + 4] = (udpLen shr 8).toByte()
        pkt[ihl + 5] = (udpLen and 0xFF).toByte()
        pkt[ihl + 6] = 0; pkt[ihl + 7] = 0  // UDPチェックサムは0でよい（IPv4では省略可）

        System.arraycopy(dnsPayload, 0, pkt, ihl + 8, dnsPayload.size)
        return pkt
    }

    // IPヘッダーチェックサム計算（RFC 1071）
    private fun ipChecksum(data: ByteArray, offset: Int, length: Int): Int {
        var sum = 0
        var i = offset
        while (i < offset + length - 1) {
            sum += ((data[i].toInt() and 0xFF) shl 8) or (data[i + 1].toInt() and 0xFF)
            i += 2
        }
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
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

    private fun updateNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(1, buildNotification())
    }

    private fun buildNotification(): Notification {
        val channelId = "toxov_vpn"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(channelId, "Toxov", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
        val text = if (tunnel != null) "ブロック動作中" else "スタンバイ中"
        return Notification.Builder(this, channelId)
            .setContentTitle("Toxov")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .build()
    }

    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
}
