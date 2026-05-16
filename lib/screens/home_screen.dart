import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/vpn_bridge.dart';
import '../services/app_blocker_bridge.dart';
import 'setup_screen.dart';
import 'app_picker_screen.dart';
import 'ranking_screen.dart';
import 'logs_screen.dart';

// Stripe課金ページ（ブラウザで開く）
const _upgradeUrl = 'https://web-production-ed8c9.up.railway.app';

class HomeScreen extends StatefulWidget {
  final String configUrl;
  const HomeScreen({super.key, required this.configUrl});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ApiService _api;
  Timer? _timer;

  Map<String, dynamic>? _config;
  bool _loading = true;
  String? _error;
  bool _vpnRunning = false;
  bool _appBlockerRunning = false;
  int _blockedAppCount = 0;
  bool _emergencyLoading = false;

  bool? _lastBlockState;

  @override
  void initState() {
    super.initState();
    _api = ApiService(widget.configUrl);
    _initVpn();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _initVpn() async {
    await VpnBridge.prepareVpn();
  }

  Future<void> _poll() async {
    try {
      final config = await _api.fetchConfig();
      final shouldBlock = _shouldBlock(config);
      final emergency = config['emergency_unblock'] == true;
      final vpnRunning = await VpnBridge.isRunning();

      // VPN制御（Webサイトブロック）
      if (!emergency && shouldBlock && !vpnRunning) {
        final sites = List<String>.from(config['sites'] ?? []);
        await VpnBridge.startVpn(sites);
        if (_lastBlockState == false) _api.postEvent('block_start').ignore();
        _lastBlockState = true;
      } else if ((emergency || !shouldBlock) && vpnRunning) {
        await VpnBridge.stopVpn();
        if (_lastBlockState == true) {
          _api.postEvent(emergency ? 'emergency_unblock' : 'block_end').ignore();
        }
        _lastBlockState = false;
      } else {
        _lastBlockState ??= shouldBlock && !emergency;
      }

      // アプリブロッカー制御
      final packages = await StorageService.getAndroidPackages();
      _blockedAppCount = packages.length;
      if (packages.isNotEmpty) {
        final hasUsage   = await AppBlockerBridge.hasUsagePermission();
        final hasOverlay = await AppBlockerBridge.hasOverlayPermission();
        if (!hasUsage && mounted) {
          _showUsagePermissionDialog();
        } else if (!hasOverlay && mounted) {
          _showOverlayPermissionDialog();
        } else if (hasUsage) {
          await AppBlockerBridge.startBlocker(
            packages: packages,
            blockStart: config['block_start'] as String? ?? '08:00',
            blockEnd: config['block_end'] as String? ?? '21:00',
            emergency: emergency,
          );
        }
      } else {
        await AppBlockerBridge.stopBlocker();
      }

      final nowVpn     = await VpnBridge.isRunning();
      final nowBlocker = await AppBlockerBridge.isRunning();

      if (mounted) {
        setState(() {
          _config          = config;
          _loading         = false;
          _error           = null;
          _vpnRunning      = nowVpn;
          _appBlockerRunning = nowBlocker;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error   = 'サーバーに接続できません';
          _loading = false;
        });
      }
    }
  }

  bool _shouldBlock(Map<String, dynamic> config) {
    if (config['emergency_unblock'] == true) return false;
    final now   = TimeOfDay.now();
    final start = (config['block_start'] as String).split(':');
    final end   = (config['block_end']   as String).split(':');
    final nowMin   = now.hour * 60 + now.minute;
    final startMin = int.parse(start[0]) * 60 + int.parse(start[1]);
    final endMin   = int.parse(end[0])   * 60 + int.parse(end[1]);
    return nowMin >= startMin && nowMin < endMin;
  }

  Future<void> _activateEmergency() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('緊急解除', style: TextStyle(color: Colors.white)),
        content: const Text(
          'ブロックを解除します。\nシーズンポイントが 6pt 減少します。\nストリークもリセットされます。',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル', style: TextStyle(color: Color(0xFF555555))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('解除する', style: TextStyle(color: Color(0xFFFF6B6B))),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _emergencyLoading = true);
    try {
      final res = await _api.activateEmergency();
      final shieldUsed = res['shield_used'] == true;
      await _poll();
      if (mounted && shieldUsed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🛡 ストリークシールドを消費しました'),
            backgroundColor: Color(0xFF1A1A1A),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エラーが発生しました')),
        );
      }
    } finally {
      if (mounted) setState(() => _emergencyLoading = false);
    }
  }

  Future<void> _logout() async {
    await VpnBridge.stopVpn();
    await AppBlockerBridge.stopBlocker();
    await StorageService.clearUrl();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SetupScreen()),
      );
    }
  }

  void _showOverlayPermissionDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('フローティング表示の許可が必要です',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: const Text(
          '特別なアクセス → フローティング表示 → Toxov をオン',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('あとで', style: TextStyle(color: Color(0xFF555555))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              AppBlockerBridge.requestOverlayPermission();
            },
            child: const Text('設定を開く', style: TextStyle(color: Color(0xFF4DABF7))),
          ),
        ],
      ),
    );
  }

  void _showUsagePermissionDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('権限が必要です',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
          '特別なアクセス → 使用履歴データへのアクセス → Toxov をオン',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('あとで', style: TextStyle(color: Color(0xFF555555))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              AppBlockerBridge.requestUsagePermission();
            },
            child: const Text('設定を開く', style: TextStyle(color: Color(0xFF4DABF7))),
          ),
        ],
      ),
    );
  }

  Future<void> _openAppPicker() async {
    final plan = _config?['plan'] as String? ?? 'free';
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AppPickerScreen(plan: plan)),
    );
    await _poll();
  }

  Future<void> _openUpgradePage() async {
    final uri = Uri.parse(_upgradeUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final emergency  = _config?['emergency_unblock'] == true;
    final blocking   = _vpnRunning && !emergency;
    final streak     = _config?['streak'] ?? 0;
    final seasonPts   = _config?['season_points'] ?? 0;
    final lifetimePts = _config?['lifetime_points'] ?? 0;
    final rankData   = _config?['rank'] as Map<String, dynamic>?;
    final rankName   = _rankJa(rankData?['name'] as String? ?? 'Seed');
    final rankNext   = rankData?['next'] as String?;
    final rankProg   = (rankData?['progress'] as num?)?.toInt() ?? 0;
    final ptsToNext  = (rankData?['pts_to_next'] as num?)?.toInt() ?? 0;
    final shouldBlockNow = _config != null && _shouldBlock(_config!) && !emergency;
    final isPremium  = (_config?['plan'] as String?) == 'premium';

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _poll,
          color: const Color(0xFF4DABF7),
          backgroundColor: const Color(0xFF1A1A1A),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // ヘッダー
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Toxov',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1)),
                  TextButton(
                    onPressed: _logout,
                    child: const Text('接続解除',
                        style: TextStyle(color: Color(0xFF555555), fontSize: 13)),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(color: Color(0xFF4DABF7)),
                  ),
                )
              else if (_error != null)
                _card(child: Column(children: [
                  Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B))),
                  TextButton(
                      onPressed: _poll,
                      child: const Text('再試行',
                          style: TextStyle(color: Color(0xFF4DABF7)))),
                ]))
              else ...[
                // ── ストリークカード ──
                _card(child: Center(child: Column(children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('$streak',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 52,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -2)),
                      const SizedBox(width: 6),
                      const Text('日連続',
                          style: TextStyle(color: Color(0xFF888888), fontSize: 16)),
                    ],
                  ),
                  const Text('緊急解除なしで継続中',
                      style: TextStyle(color: Color(0xFF555555), fontSize: 12)),
                ]))),
                const SizedBox(height: 12),

                // ── サイトブロック状態カード ──
                _card(child: Row(children: [
                  _dot(emergency
                      ? const Color(0xFFFFA94D)
                      : blocking
                          ? const Color(0xFFFF6B6B)
                          : const Color(0xFF69DB7C)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          emergency ? '緊急解除中' : blocking ? 'ブロック中' : '解除中',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500),
                        ),
                        if (_config != null)
                          Text(
                            '${_config!['block_start']} ～ ${_config!['block_end']}',
                            style: const TextStyle(
                                color: Color(0xFF555555), fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                  const Text('サイト',
                      style: TextStyle(color: Color(0xFF555555), fontSize: 11)),
                ])),
                const SizedBox(height: 8),

                // ── アプリブロックカード ──
                GestureDetector(
                  onTap: _openAppPicker,
                  child: _card(child: Row(children: [
                    _dot(_appBlockerRunning && blocking
                        ? const Color(0xFFFF6B6B)
                        : _blockedAppCount > 0
                            ? const Color(0xFF69DB7C)
                            : const Color(0xFF444444)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _blockedAppCount == 0
                                ? 'アプリを選択してください'
                                : _appBlockerRunning && blocking
                                    ? 'アプリブロック中'
                                    : 'アプリブロック待機中',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w500),
                          ),
                          if (_blockedAppCount > 0 && _config != null)
                            Text(
                              '$_blockedAppCount個設定済・${_config!['block_start']}〜${_config!['block_end']}に有効',
                              style: const TextStyle(
                                  color: Color(0xFF555555), fontSize: 12),
                            )
                          else
                            const Text('タップしてアプリを選択',
                                style: TextStyle(
                                    color: Color(0xFF555555), fontSize: 12)),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right,
                        color: Color(0xFF555555), size: 20),
                  ])),
                ),
                const SizedBox(height: 8),

                // ── ポイント・ランクカード ──
                GestureDetector(
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(
                          builder: (_) => RankingScreen(api: _api))),
                  child: _card(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(children: [
                            Text(_rankEmoji(rankData?['name'] as String? ?? 'Seed'),
                                style: const TextStyle(fontSize: 18)),
                            const SizedBox(width: 8),
                            Text(rankName,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                          ]),
                          Row(children: [
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Row(children: [
                                const Text('S ',
                                    style: TextStyle(color: Color(0xFF555555), fontSize: 11)),
                                Text('$seasonPts pt',
                                    style: const TextStyle(
                                        color: Color(0xFF4DABF7),
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700)),
                              ]),
                              Row(children: [
                                const Text('総 ',
                                    style: TextStyle(color: Color(0xFF555555), fontSize: 11)),
                                Text('$lifetimePts pt',
                                    style: const TextStyle(
                                        color: Color(0xFF888888),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500)),
                              ]),
                            ]),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right,
                                color: Color(0xFF555555), size: 20),
                          ]),
                        ],
                      ),
                      if (rankNext != null) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: rankProg / 100,
                            minHeight: 4,
                            backgroundColor: const Color(0xFF2A2A2A),
                            valueColor: const AlwaysStoppedAnimation(
                                Color(0xFF4DABF7)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '次のランク（${_rankJa(rankNext)}）まで $ptsToNext pt',
                          style: const TextStyle(
                              color: Color(0xFF555555), fontSize: 11),
                        ),
                      ],
                    ],
                  )),
                ),
                const SizedBox(height: 8),

                // ── ログカード ──
                GestureDetector(
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(
                          builder: (_) => LogsScreen(api: _api))),
                  child: _card(child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text('ログ',
                          style: TextStyle(
                              color: Color(0xFF888888),
                              fontSize: 13,
                              letterSpacing: 0.5)),
                      Row(children: [
                        Text('詳細を見る',
                            style: TextStyle(
                                color: Color(0xFF4DABF7), fontSize: 13)),
                        Icon(Icons.chevron_right,
                            color: Color(0xFF4DABF7), size: 18),
                      ]),
                    ],
                  )),
                ),
                const SizedBox(height: 8),

                // ── Premiumアップグレードバナー（無料プランのみ表示）──
                if (!isPremium && _config != null)
                  GestureDetector(
                    onTap: _openUpgradePage,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1A1228), Color(0xFF1A1A2E)],
                        ),
                        border: Border.all(
                            color: const Color(0xFF7950F2).withValues(alpha: 0.4)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Text('⚡', style: TextStyle(fontSize: 20)),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Premium にアップグレード',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700)),
                                SizedBox(height: 2),
                                Text('アプリブロック無制限・シールドなど',
                                    style: TextStyle(
                                        color: Color(0xFF888888),
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: Color(0xFF7950F2), size: 20),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),

                // ── 緊急解除ボタン（ブロック時間内のみ表示）──
                if (shouldBlockNow)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _emergencyLoading ? null : _activateEmergency,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF6B6B),
                        side: const BorderSide(color: Color(0xFF3A1A1A)),
                        backgroundColor: const Color(0xFF1A0A0A),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _emergencyLoading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFFFF6B6B)))
                          : const Text('緊急解除（-6pt・ストリークリセット）',
                              style: TextStyle(fontSize: 13)),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: color, blurRadius: 6)],
        ),
      );

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  String _rankJa(String name) => const {
        'Diamond': 'ダイヤ',
        'Gold': 'ゴールド',
        'Iron': 'アイアン',
        'Flame': 'フレーム',
        'Seed': 'シード',
      }[name] ??
      name;

  String _rankEmoji(String name) => const {
        'Diamond': '💎',
        'Gold': '🥇',
        'Iron': '🪨',
        'Flame': '🔥',
        'Seed': '🌱',
      }[name] ??
      '🌱';
}
