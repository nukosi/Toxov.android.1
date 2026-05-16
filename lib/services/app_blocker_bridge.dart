import 'package:flutter/services.dart';

// KotlinのAppBlockerServiceをFlutterから操作するMethodChannelブリッジ
class AppBlockerBridge {
  static const _channel = MethodChannel('com.toxov/app_blocker');

  // PACKAGE_USAGE_STATS権限が付与されているか確認する
  static Future<bool> hasUsagePermission() async {
    final result = await _channel.invokeMethod<bool>('hasUsagePermission');
    return result ?? false;
  }

  // 使用状況アクセスの設定画面を開く
  static Future<void> requestUsagePermission() async {
    await _channel.invokeMethod('requestUsagePermission');
  }

  // システムアプリを除くインストール済みアプリ一覧を返す
  // 返り値: [{packageName: String, appName: String}]
  static Future<List<Map<String, String>>> getInstalledApps() async {
    final result = await _channel.invokeMethod<List>('getInstalledApps');
    if (result == null) return [];
    return result
        .cast<Map>()
        .map((m) => {
              'packageName': m['packageName'] as String,
              'appName': m['appName'] as String,
            })
        .toList();
  }

  // アプリブロッカーを開始・更新する
  // packages: ブロックするパッケージ名リスト
  // blockStart / blockEnd: "HH:MM" 形式
  // emergency: 緊急解除中かどうか
  static Future<void> startBlocker({
    required List<String> packages,
    required String blockStart,
    required String blockEnd,
    required bool emergency,
  }) async {
    await _channel.invokeMethod('startBlocker', {
      'packages': packages,
      'blockStart': blockStart,
      'blockEnd': blockEnd,
      'emergency': emergency,
    });
  }

  // アプリブロッカーを停止する
  static Future<void> stopBlocker() async {
    await _channel.invokeMethod('stopBlocker');
  }

  // アプリブロッカーが動作中かどうかを確認する
  static Future<bool> isRunning() async {
    final result = await _channel.invokeMethod<bool>('isBlockerRunning');
    return result ?? false;
  }

  // SYSTEM_ALERT_WINDOW（フローティング表示）権限が付与されているか確認する
  static Future<bool> hasOverlayPermission() async {
    final result = await _channel.invokeMethod<bool>('hasOverlayPermission');
    return result ?? false;
  }

  // フローティング表示の設定画面を開く
  static Future<void> requestOverlayPermission() async {
    await _channel.invokeMethod('requestOverlayPermission');
  }
}
