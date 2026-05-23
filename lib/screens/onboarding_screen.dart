import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/app_blocker_bridge.dart';
import '../services/storage_service.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final String configUrl;
  const OnboardingScreen({super.key, required this.configUrl});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

// プリセットサイト1件（block_settings_screen.dartと同じ定義）
class _PS {
  final String name;
  final List<String> domains;
  const _PS(this.name, this.domains);
}

// プリセットカテゴリ
class _PC {
  final String name;
  final List<_PS> sites;
  const _PC(this.name, this.sites);
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  int _step = 0;

  // 権限チェック結果
  bool _hasUsage   = false;
  bool _hasOverlay = false;
  bool _hasBattery = false;

  // ステップ4（ブロック設定）用
  late final ApiService _api;
  List<String> _step4Sites     = [];
  bool _step4Loading            = false;
  bool _step4Initialized        = false;
  bool _step4Saving             = false;

  // web.pyのPRESET_SITESと同じ定義（サーバー側と必ず揃えること）
  static const _presets = [
    _PC('動画', [
      _PS('YouTube',  ['youtube.com', 'www.youtube.com', 'youtu.be']),
      _PS('Netflix',  ['netflix.com']),
      _PS('Twitch',   ['twitch.tv']),
      _PS('ニコニコ', ['nicovideo.jp']),
    ]),
    _PC('SNS', [
      _PS('X',         ['x.com', 'twitter.com']),
      _PS('Instagram', ['instagram.com']),
      _PS('TikTok',    ['tiktok.com']),
      _PS('Reddit',    ['reddit.com']),
      _PS('Facebook',  ['facebook.com']),
      _PS('Discord',   ['discord.com']),
    ]),
    _PC('アダルト', [
      _PS('Pornhub',  ['pornhub.com']),
      _PS('xVideos',  ['xvideos.com']),
      _PS('xHamster', ['xhamster.com']),
    ]),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
    _api = ApiService(widget.configUrl);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // アプリがフォアグラウンドに戻ったら権限を再チェック
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final usage   = await AppBlockerBridge.hasUsagePermission();
    final overlay = await AppBlockerBridge.hasOverlayPermission();
    final battery = await AppBlockerBridge.hasBatteryOptimizationExemption();
    if (mounted) {
      setState(() {
        _hasUsage   = usage;
        _hasOverlay = overlay;
        _hasBattery = battery;
      });
    }
  }

  void _next() {
    if (_step < 4) {
      final next = _step + 1;
      setState(() => _step = next);
      // ステップ4に入ったらサーバーから現在のサイトリストを取得する
      if (next == 4) _initStep4();
    } else {
      _finish();
    }
  }

  // サーバーから現在のサイトリストを取得してステップ4の初期値にする
  Future<void> _initStep4() async {
    if (_step4Initialized) return;
    setState(() => _step4Loading = true);
    try {
      final config = await _api.fetchConfig();
      _step4Sites = List<String>.from(config['sites'] as List? ?? []);
      _step4Initialized = true;
    } catch (_) {
      // 取得失敗時は空リストで続行する
      _step4Initialized = true;
    } finally {
      if (mounted) setState(() => _step4Loading = false);
    }
  }

  Future<void> _finish() async {
    await StorageService.setOnboardingDone();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomeScreen(configUrl: widget.configUrl),
        ),
      );
    }
  }

  // ステップ4で選択したサイトをサーバーに保存してからオンボーディングを完了する
  Future<void> _saveAndFinish() async {
    setState(() => _step4Saving = true);
    try {
      await _api.saveSites(_step4Sites);
    } catch (_) {
      // 保存失敗してもオンボーディングは完了させる
    }
    await _finish();
  }

  bool _presetActive(_PS ps) => ps.domains.every(_step4Sites.contains);

  void _togglePreset(_PS ps) {
    setState(() {
      if (_presetActive(ps)) {
        _step4Sites.removeWhere(ps.domains.contains);
      } else {
        for (final d in ps.domains) {
          if (!_step4Sites.contains(d)) _step4Sites.add(d);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              // プログレスインジケーター
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) => _dot(i)),
              ),
              const SizedBox(height: 48),

              Expanded(child: _buildStep()),

              const SizedBox(height: 24),
              _buildButtons(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(int index) {
    final active = index == _step;
    final done   = index < _step;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: active ? 24 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: done || active
            ? const Color(0xFFF97316)
            : const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  Widget _buildStep() {
    return switch (_step) {
      0 => _stepView(
          icon: '🎉',
          title: 'Toxovへようこそ',
          description: 'サイトとアプリを時間帯で自動ブロックして、集中できる環境をつくります。\n\nはじめに必要な権限を3つ設定します。',
          granted: null,
        ),
      1 => _stepView(
          icon: '📊',
          title: '使用履歴へのアクセス',
          description: 'ブロック中にアプリを開こうとすると自動で閉じるために必要です。\n\n次の画面で「Toxov」を探してオンにしてください。',
          granted: _hasUsage,
        ),
      2 => _stepView(
          icon: '🔲',
          title: 'フローティング表示',
          description: 'ブロック中にアプリを開いたとき警告を表示するために必要です。\n\n次の画面で「Toxov」を探してオンにしてください。',
          granted: _hasOverlay,
        ),
      3 => _stepView(
          icon: '🔋',
          title: 'バッテリー最適化',
          description: 'バックグラウンドでブロック機能が停止しないようにするために必要です。\n\n次の画面で「制限しない」を選んでください。',
          granted: _hasBattery,
        ),
      // ステップ4：実際にサイトを選択して初期設定するインタラクティブなステップ
      _ => _buildBlockSettingsStep(),
    };
  }

  Widget _buildBlockSettingsStep() {
    if (_step4Loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFF97316)),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('🛡', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 16),
          const Text('ブロック設定',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          const SizedBox(height: 10),
          const Text(
              'ブロックしたいサイトを選んでください。\nあとからいつでも変更できます。',
              style: TextStyle(
                  color: Color(0xFF888888), fontSize: 14, height: 1.6)),
          const SizedBox(height: 24),

          // カテゴリ別プリセットチップ
          for (final cat in _presets) ...[
            Text(cat.name,
                style: const TextStyle(
                    color: Color(0xFF555555),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final site in cat.sites)
                  _OnboardingChip(
                    label: site.name,
                    active: _presetActive(site),
                    onTap: () => _togglePreset(site),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _stepView({
    required String icon,
    required String title,
    required String description,
    required bool? granted,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(icon, style: const TextStyle(fontSize: 64)),
        const SizedBox(height: 28),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5)),
        const SizedBox(height: 16),
        Text(description,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Color(0xFF888888), fontSize: 14, height: 1.7)),
        if (granted == true) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2A1A),
              border: Border.all(color: const Color(0xFF2A4A2A)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: Color(0xFF4ADE80), size: 16),
                SizedBox(width: 6),
                Text('許可済み',
                    style: TextStyle(color: Color(0xFF4ADE80), fontSize: 13)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildButtons() {
    // ウェルカムステップ
    if (_step == 0) {
      return _primaryButton('始める', _next);
    }

    // ブロック設定ステップ：選択を保存してホーム画面へ
    if (_step == 4) {
      return Column(
        children: [
          _primaryButton(
            _step4Saving ? '保存中...' : '完了',
            _step4Saving ? () {} : _saveAndFinish,
          ),
          const SizedBox(height: 10),
          // ブロックするものが何もない場合などに使うスキップ
          TextButton(
            onPressed: _step4Saving ? null : _finish,
            child: const Text('スキップ',
                style: TextStyle(color: Color(0xFF555555), fontSize: 14)),
          ),
        ],
      );
    }

    // バッテリーステップで全権限が揃っていたら次のステップへ進む
    final allGranted = _hasUsage && _hasOverlay && _hasBattery;
    if (_step == 3 && allGranted) {
      return _primaryButton('次へ', _next);
    }

    // 権限ステップ（1・2・3）
    final granted = switch (_step) {
      1 => _hasUsage,
      2 => _hasOverlay,
      _ => _hasBattery,
    };

    final onRequest = switch (_step) {
      1 => AppBlockerBridge.requestUsagePermission,
      2 => AppBlockerBridge.requestOverlayPermission,
      _ => AppBlockerBridge.requestBatteryOptimizationExemption,
    };

    return Column(
      children: [
        if (!granted)
          _primaryButton('設定を開く', () async {
            await onRequest();
            await _checkPermissions();
          }),
        if (granted)
          _primaryButton('次へ', _next),
        if (!granted) ...[
          const SizedBox(height: 10),
          TextButton(
            onPressed: _next,
            child: const Text('スキップ',
                style: TextStyle(color: Color(0xFF555555), fontSize: 14)),
          ),
        ],
      ],
    );
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFF97316),
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 16)),
      ),
    );
  }
}

// オンボーディング用プリセット選択チップ
class _OnboardingChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _OnboardingChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFFF97316).withValues(alpha: 0.15)
              : const Color(0xFF1A1A1A),
          border: Border.all(
              color: active
                  ? const Color(0xFFF97316)
                  : const Color(0xFF2A2A2A)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
              color: active
                  ? const Color(0xFFF97316)
                  : const Color(0xFF888888),
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400),
        ),
      ),
    );
  }
}
