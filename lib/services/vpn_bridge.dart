import 'package:flutter/services.dart';

// KotlinのToxovVpnServiceをFlutterから操作するMethodChannelブリッジ
class VpnBridge {
  static const _channel = MethodChannel('com.toxov/vpn');

  // VPN使用許可をユーザーに求める。"already_granted" or "granted" or "denied" を返す
  static Future<String> prepareVpn() async {
    final result = await _channel.invokeMethod<String>('prepareVpn');
    return result ?? 'denied';
  }

  // VPN設定を送信してサービスを起動・更新する。
  // サービスはスケジュールを自律管理するため、アプリが閉じていてもブロックが継続する。
  // blockUntil: 期間ブロックの終了日時（JST ISO文字列 "YYYY-MM-DDTHH:mm:ss"）。nullで通常スケジュールのみ
  static Future<void> startVpn({
    required List<String> sites,
    required String blockStart,
    required String blockEnd,
    required bool emergency,
    String? blockUntil,
  }) async {
    await _channel.invokeMethod('startVpn', {
      'sites':      sites,
      'blockStart': blockStart,
      'blockEnd':   blockEnd,
      'emergency':  emergency,
      if (blockUntil != null) 'blockUntil': blockUntil,
    });
  }

  // VPNを完全停止する（ログアウト時など）
  static Future<void> stopVpn() async {
    await _channel.invokeMethod('stopVpn');
  }

  // VPNが現在ブロック動作中かどうかを確認する
  static Future<bool> isRunning() async {
    final result = await _channel.invokeMethod<bool>('isRunning');
    return result ?? false;
  }

  // 緊急解除から24時間後にブロックを自動再開するAlarmManagerアラームをセットする
  static Future<void> scheduleEmergencyResume({
    required String resumeUrl,
    int delayMs = 24 * 3600 * 1000,
  }) async {
    await _channel.invokeMethod('scheduleEmergencyResume', {
      'delayMs':   delayMs,
      'resumeUrl': resumeUrl,
    });
  }

  // 緊急解除アラームをキャンセルする（手動でブロックに戻ったとき）
  static Future<void> cancelEmergencyResume() async {
    await _channel.invokeMethod('cancelEmergencyResume');
  }
}
