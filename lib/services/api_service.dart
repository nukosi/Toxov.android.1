import 'dart:convert';
import 'package:http/http.dart' as http;

// サーバー側のAGENT_SECRET環境変数と同じ値。agent.pyと揃えること
const _agentSecret = 'toxov-prod-abc123xyz';
const _serverBase = 'https://web-production-ed8c9.up.railway.app';

// Toxovサーバー（Railway）とのAPI通信サービス
class ApiService {
  final String configUrl;

  static const _headers = {'X-Toxov-Key': _agentSecret};

  String get logUrl       => configUrl.replaceFirst('/api/config/', '/api/log/');
  String get emergencyUrl => configUrl.replaceFirst('/api/config/', '/api/emergency/');
  String get statsUrl     => configUrl.replaceFirst('/api/config/', '/api/stats/');

  ApiService(this.configUrl);

  // 6文字コードからconfig URLを解決する（初回セットアップ用）
  static Future<String> resolveCode(String code) async {
    final res = await http
        .get(Uri.parse('$_serverBase/api/connect/$code'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('invalid_code');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['config_url'] as String;
  }

  // サーバーから設定・ストリーク・ポイント・ランクを取得する
  Future<Map<String, dynamic>> fetchConfig() async {
    final res = await http
        .get(Uri.parse(configUrl), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ブロックイベントをサーバーに送信する
  Future<void> postEvent(String event) async {
    await http
        .post(
          Uri.parse(logUrl),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode({'event': event}),
        )
        .timeout(const Duration(seconds: 5));
  }

  // 緊急解除を発動する（ポイントペナルティあり）
  Future<Map<String, dynamic>> activateEmergency() async {
    final res = await http
        .post(Uri.parse(emergencyUrl), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ランキング・ログなどの統計情報を取得する
  Future<Map<String, dynamic>> fetchStats() async {
    final res = await http
        .get(Uri.parse(statsUrl), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
