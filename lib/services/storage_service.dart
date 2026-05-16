import 'package:shared_preferences/shared_preferences.dart';

// トークンURLとAndroidブロック対象パッケージ名をデバイスにローカル保存するサービス
class StorageService {
  static const _keyUrl = 'cloud_url';
  static const _keyAndroidPackages = 'android_packages';

  static Future<String?> getUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUrl);
  }

  static Future<void> saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUrl, url);
  }

  static Future<void> clearUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUrl);
  }

  // ブロック対象Androidアプリのパッケージ名リストを取得する
  static Future<List<String>> getAndroidPackages() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyAndroidPackages) ?? [];
  }

  // ブロック対象Androidアプリのパッケージ名リストを保存する
  static Future<void> saveAndroidPackages(List<String> packages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyAndroidPackages, packages);
  }
}
