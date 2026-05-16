import 'package:flutter/services.dart';

// KotlinのToxovVpnServiceをFlutterから操作するMethodChannelブリッジ
class VpnBridge {
  static const _channel = MethodChannel('com.toxov/vpn');

  // VPN使用許可をユーザーに求める。"already_granted" or "granted" or "denied" を返す
  static Future<String> prepareVpn() async {
    final result = await _channel.invokeMethod<String>('prepareVpn');
    return result ?? 'denied';
  }

  // VPNを開始してブロック対象ドメインリストを渡す
  static Future<void> startVpn(List<String> sites) async {
    await _channel.invokeMethod('startVpn', {'sites': sites});
  }

  // VPNを停止する
  static Future<void> stopVpn() async {
    await _channel.invokeMethod('stopVpn');
  }

  // VPNが動作中かどうかを確認する
  static Future<bool> isRunning() async {
    final result = await _channel.invokeMethod<bool>('isRunning');
    return result ?? false;
  }
}
