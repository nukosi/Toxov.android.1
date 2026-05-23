import 'package:flutter/material.dart';
import '../services/app_blocker_bridge.dart';
import '../services/storage_service.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final String configUrl;
  const OnboardingScreen({super.key, required this.configUrl});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  int _step = 0;

  // 権限チェック結果
  bool _hasUsage   = false;
  bool _hasOverlay = false;
  bool _hasBattery = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // アプリがフォアグラウンドに戻ったら権限を再チェック
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
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
      setState(() => _step++);
    } else {
      _finish();
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
      // ブロック設定タブの紹介ステップ（権限不要）
      _ => _stepView(
          icon: '🛡',
          title: 'ブロック設定',
          description: 'ブロック設定タブから、YouTube・X・Instagramなどのサイトや、特定のアプリをブロックできます。\n\nサイトはPCと共有されるので、PC側の設定もそのまま引き継がれます。',
          granted: null,
        ),
    };
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

    // ブロック設定紹介ステップは常に完了ボタン（権限不要）
    if (_step == 4) {
      return _primaryButton('完了', _finish);
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
