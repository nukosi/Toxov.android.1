import 'dart:convert';
import 'package:http/http.dart' as http;

// サーバー側のAGENT_SECRET環境変数と同じ値。agent.pyと揃えること
const _agentSecret = 'toxov-prod-abc123xyz';
const _serverBase = 'https://web-production-ed8c9.up.railway.app';

// Toxovサーバー（Railway）とのAPI通信サービス
class ApiService {
  final String configUrl;

  static const _headers = {'X-Toxov-Key': _agentSecret};

  String get logUrl              => configUrl.replaceFirst('/api/config/', '/api/log/');
  String get emergencyUrl        => configUrl.replaceFirst('/api/config/', '/api/emergency/');
  String get resumeUrl           => configUrl.replaceFirst('/api/config/', '/api/resume/');
  String get statsUrl            => configUrl.replaceFirst('/api/config/', '/api/stats/');
  String get adminSetPlanUrl     => configUrl.replaceFirst('/api/config/', '/api/admin/set-plan/');
  String get blockUntilSetUrl    => configUrl.replaceFirst('/api/config/', '/api/block-until/set/');
  String get blockUntilCancelUrl => configUrl.replaceFirst('/api/config/', '/api/block-until/cancel/');

  ApiService(this.configUrl);

  // メール/パスワードでログインしてconfig URLを取得する
  static Future<String> mobileLogin(String email, String password) async {
    final res = await http
        .post(
          Uri.parse('$_serverBase/api/mobile/login'),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 401) throw Exception('invalid_credentials');
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['config_url'] as String;
  }

  // 新規ユーザー登録してconfig URLを取得する
  static Future<String> mobileRegister(String username, String email, String password) async {
    final res = await http
        .post(
          Uri.parse('$_serverBase/api/mobile/register'),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode({'username': username, 'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 409) {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(json['error'] as String);
    }
    if (res.statusCode != 201) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['config_url'] as String;
  }

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

  // 緊急解除を終了してブロックを再開する
  Future<void> resumeEmergency() async {
    final res = await http
        .post(Uri.parse(resumeUrl), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  }

  // ランキング・ログなどの統計情報を取得する
  Future<Map<String, dynamic>> fetchStats() async {
    final res = await http
        .get(Uri.parse(statsUrl), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // 利用可能な料金プラン一覧を取得する
  Future<List<Map<String, dynamic>>> fetchMobilePlans() async {
    final url = configUrl.replaceFirst('/api/config/', '/api/mobile/plans/');
    final res = await http
        .get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return (json['plans'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // 管理者専用：プランをfree/premiumに切り替える
  Future<void> adminSetPlan(String plan) async {
    final res = await http
        .post(
          Uri.parse(adminSetPlanUrl),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode({'plan': plan}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  }

  // モバイルからサイトリストをサーバーに保存する（ブロック時間中は制限あり）
  Future<void> saveSites(List<String> sites) async {
    final url = configUrl.replaceFirst('/api/config/', '/api/sites/save/');
    final res = await http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode({'sites': sites}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 403) {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(json['error'] as String? ?? 'forbidden');
    }
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  }

  // 期間ブロックを設定する。無料プランは最大24時間まで。サーバー側で上限を適用する
  Future<String?> setBlockUntil(int days, int hours) async {
    final res = await http
        .post(
          Uri.parse(blockUntilSetUrl),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode({'days': days, 'hours': hours}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['until'] as String?;
  }

  // 期間ブロックをキャンセルする
  Future<void> cancelBlockUntil() async {
    final res = await http
        .post(Uri.parse(blockUntilCancelUrl), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
  }

  // モバイル向けStripe Checkoutセッションを生成してURLを返す
  Future<String> fetchMobileCheckoutUrl({String plan = 'monthly'}) async {
    final url = '${configUrl.replaceFirst('/api/config/', '/api/mobile/checkout/')}?plan=$plan';
    final res = await http
        .get(Uri.parse(url), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['url'] as String;
  }
}
