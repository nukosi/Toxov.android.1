import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:confetti/confetti.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/vpn_bridge.dart';
import '../services/app_blocker_bridge.dart';
import '../services/notification_service.dart';
import '../services/widget_service.dart';
import 'setup_screen.dart';
import 'app_picker_screen.dart';
import 'ranking_screen.dart';
import 'logs_screen.dart';
import 'block_settings_screen.dart'; // サイト・アプリブロック設定タブ
import 'onboarding_screen.dart';     // オンボーディングリセット（admin用）


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
  bool _resumeLoading = false;
  int _tabIndex = 0;

  bool? _lastBlockState;
  bool? _lastScheduleState; // スケジュールウィンドウ（08:00-21:00）の前回状態（期間ブロック中のポイント加算に使用）
  // シールド使用直後のpollでemergency_unblockを二重送信しないためのフラグ。
  // モバイル側で/api/emergencyがシールドを消費した直後に_poll()がemergency_unblockを
  // /api/logに送ると、シールドが既に0なので実際の緊急解除として記録されストリークが消える。
  bool _shieldJustUsed = false;
  late final ConfettiController _confettiController;
  int? _lastKnownStreak; // 前回pollのストリーク値（節目検知用）

  static const _milestones = [7, 30, 100];

  @override
  void initState() {
    super.initState();
    _api = ApiService(widget.configUrl);
    _confettiController = ConfettiController(duration: const Duration(seconds: 4));
    _initVpn();
    NotificationService.init();
    _poll();
    _checkBatteryOptimization();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _confettiController.dispose();
    super.dispose();
  }

  Future<void> _initVpn() async {
    await VpnBridge.prepareVpn();
  }

  Future<void> _checkBatteryOptimization() async {
    final exempt = await AppBlockerBridge.hasBatteryOptimizationExemption();
    if (!exempt && mounted) {
      _showBatteryOptimizationDialog();
    }
  }

  void _showBatteryOptimizationDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('バッテリー最適化を無効にしてください',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: const Text(
          'バッテリー最適化が有効だと、ブロック機能がバックグラウンドで停止することがあります。\n\n「制限しない」に設定してください。',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('あとで',
                style: TextStyle(color: Color(0xFF555555))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              AppBlockerBridge.requestBatteryOptimizationExemption();
            },
            child: const Text('設定を開く',
                style: TextStyle(color: Color(0xFFF97316))),
          ),
        ],
      ),
    );
  }

  Future<void> _poll() async {
    try {
      final config = await _api.fetchConfig();
      final emergency  = config['emergency_unblock'] == true;
      final sites      = List<String>.from(config['sites'] ?? []);
      final blockStart = config['block_start'] as String? ?? '08:00';
      final blockEnd   = config['block_end']   as String? ?? '21:00';
      final blockUntil = config['block_until'] as String?;

      // VPN設定を常にサービスへ送信する。
      // サービスがスケジュールを自律管理するため、アプリが閉じていてもブロックが継続する。
      await VpnBridge.startVpn(
        sites:      sites,
        blockStart: blockStart,
        blockEnd:   blockEnd,
        emergency:  emergency,
        blockUntil: blockUntil,
      );

      // ブロック状態の変化を検知してイベントをサーバーに記録する。
      // VPN状態ではなくスケジュール時刻の切り替わりに基づいて発火することで、
      // 期間ブロック中（VPN24時間稼働）でもポイントが正常に加算される。
      final vpnRunning = await VpnBridge.isRunning();
      final scheduleActive = _isInScheduleWindow(blockStart, blockEnd);
      if (emergency) {
        // 緊急解除中: VPN停止を検知したら emergency_unblock を記録する。
        // ただしシールド使用直後のpollは除く（_shieldJustUsedフラグで抑制）。
        if (_lastBlockState == true && !vpnRunning) {
          if (_shieldJustUsed) {
            _shieldJustUsed = false;
          } else {
            _api.postEvent('emergency_unblock').ignore();
          }
        }
        // 緊急解除解除後の次pollでblock_startが発火するようにリセットする
        _lastScheduleState = null;
      } else {
        // 通常フロー: スケジュール（08:00/21:00）の切り替わりでイベントを発火する
        if (scheduleActive && _lastScheduleState != true) {
          _api.postEvent('block_start').ignore();
        } else if (!scheduleActive && _lastScheduleState == true) {
          _api.postEvent('block_end').ignore();
        }
        _lastScheduleState = scheduleActive;
      }
      _lastBlockState = vpnRunning;

      // アプリブロッカー制御
      final packages = await StorageService.getAndroidPackages();
      _blockedAppCount = packages.length;

      // 再起動後の復帰用にブロック設定をネイティブに保存する
      if (packages.isNotEmpty) {
        AppBlockerBridge.saveBootConfig(
          packages:   packages,
          blockStart: config['block_start'] as String? ?? '08:00',
          blockEnd:   config['block_end']   as String? ?? '21:00',
        ).ignore();
      }
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
        // 節目チェック（値が変化して節目に達したときに祝福）
        _checkMilestone(config['streak'] as int? ?? 0);
        // ブロック開始・終了の通知をスケジュール
        NotificationService.scheduleBlockNotifications(
          config['block_start'] as String? ?? '08:00',
          config['block_end']   as String? ?? '21:00',
        );
        // ホーム画面ウィジェットを更新
        WidgetService.update(
          streak:      config['streak'] as int? ?? 0,
          isBlocking:  nowVpn,
          isEmergency: config['emergency_unblock'] == true,
        );
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

  // 現在時刻がスケジュールのブロック時間帯内かどうかを返す（期間ブロックは考慮しない）
  bool _isInScheduleWindow(String start, String end) {
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    int parseMin(String s) {
      final parts = s.split(':');
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    }
    return nowMin >= parseMin(start) && nowMin < parseMin(end);
  }

  bool _shouldBlock(Map<String, dynamic> config) {
    if (config['emergency_unblock'] == true) return false;
    // 期間ブロック中は時間帯に関わらず常時ブロック
    final blockUntil = config['block_until'] as String?;
    if (blockUntil != null && blockUntil.isNotEmpty) {
      try {
        final until = DateTime.parse(blockUntil); // JST前提でローカル時刻として解釈する
        if (DateTime.now().isBefore(until)) return true;
      } catch (_) {}
    }
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
      if (shieldUsed) _shieldJustUsed = true; // 次のpollでの二重送信を防ぐ
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

  Future<void> _resumeEmergency() async {
    setState(() => _resumeLoading = true);
    try {
      await _api.resumeEmergency();
      await _poll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エラーが発生しました')),
        );
      }
    } finally {
      if (mounted) setState(() => _resumeLoading = false);
    }
  }

  void _checkMilestone(int streak) {
    final prev = _lastKnownStreak;
    _lastKnownStreak = streak;
    // 前回と値が異なり、節目に到達した瞬間だけ祝福（緊急解除後の再達成も対象）
    if (prev != streak && _milestones.contains(streak)) {
      _showMilestoneCelebration(streak);
      NotificationService.showMilestone(streak);
    }
  }

  void _showMilestoneCelebration(int days) {
    _confettiController.play();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (_) => Stack(
        alignment: Alignment.topCenter,
        children: [
          ConfettiWidget(
            confettiController: _confettiController,
            blastDirectionality: BlastDirectionality.explosive,
            numberOfParticles: 30,
            colors: const [
              Color(0xFFF97316),
              Color(0xFFFFD93D),
              Color(0xFF4ADE80),
              Color(0xFF60A5FA),
            ],
          ),
          Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFF97316), width: 1.5),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      days == 7 ? '🔥' : days == 30 ? '⚡' : '👑',
                      style: const TextStyle(fontSize: 56),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '$days日達成！',
                      style: const TextStyle(
                        color: Color(0xFFF97316),
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      switch (days) {
                        7  => '1週間継続できました。\n習慣が形成されています。',
                        30 => '1ヶ月継続達成。\n本物の習慣になっています。',
                        _  => '100日継続。\nこのレベルは本物です。',
                      },
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF888888),
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF97316),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('続ける',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
            child: const Text('設定を開く', style: TextStyle(color: Color(0xFFF97316))),
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
            child: const Text('設定を開く', style: TextStyle(color: Color(0xFFF97316))),
          ),
        ],
      ),
    );
  }

  // 期間ブロックの設定ダイアログを表示し、設定する（PCと同じ日数・時間入力）
  Future<void> _showBlockUntilDialog() async {
    final isPremium  = (_config?['plan'] as String?) == 'premium';
    // await前にScaffoldMessengerを取得してasync gap越えのBuildContext参照を避ける
    final messenger  = ScaffoldMessenger.of(context);
    // 無料プランは最大24時間（日数0固定、時間1〜24）
    // Premiumは最大365日（日数0〜365、時間0〜23）
    int days  = 0;
    int hours = isPremium ? 0 : 24;
    final maxDays  = isPremium ? 365 : 0;
    final maxHours = isPremium ? 23 : 24;
    final minHours = isPremium ? 0 : 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          // 合計が0時間かどうか（設定ボタンの有効判定）
          final totalHours = days * 24 + hours;

          // カウンター行：ラベル＋マイナスボタン＋数値＋プラスボタン
          Widget counter({
            required String label,
            required int value,
            required int min,
            required int max,
            required void Function(int) onChange,
            bool disabled = false,
          }) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: const TextStyle(color: Color(0xFF888888), fontSize: 12)),
                const SizedBox(height: 8),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  // マイナスボタン
                  GestureDetector(
                    onTap: disabled || value <= min
                        ? null
                        : () => setStateDialog(() => onChange(value - 1)),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text('−',
                            style: TextStyle(
                                color: (disabled || value <= min)
                                    ? const Color(0xFF333333)
                                    : Colors.white,
                                fontSize: 18)),
                      ),
                    ),
                  ),
                  // 数値表示
                  Container(
                    width: 56,
                    alignment: Alignment.center,
                    child: Text(
                      '$value',
                      style: TextStyle(
                          color: disabled
                              ? const Color(0xFF444444)
                              : Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  // プラスボタン
                  GestureDetector(
                    onTap: disabled || value >= max
                        ? null
                        : () => setStateDialog(() => onChange(value + 1)),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text('+',
                            style: TextStyle(
                                color: (disabled || value >= max)
                                    ? const Color(0xFF333333)
                                    : Colors.white,
                                fontSize: 18)),
                      ),
                    ),
                  ),
                ]),
              ],
            );
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('期間ブロック', style: TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isPremium)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      '無料プランは最大24時間まで',
                      style: TextStyle(color: Color(0xFF888888), fontSize: 12),
                    ),
                  ),
                const Text(
                  'スケジュールを無視して、指定した期間だけ常時ブロックします。',
                  style: TextStyle(color: Color(0xFF555555), fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    counter(
                      label: '日',
                      value: days,
                      min: 0,
                      max: maxDays,
                      disabled: !isPremium,
                      onChange: (v) { days = v; },
                    ),
                    counter(
                      label: '時間',
                      value: hours,
                      min: minHours,
                      max: maxHours,
                      onChange: (v) { hours = v; },
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('キャンセル', style: TextStyle(color: Color(0xFF555555))),
              ),
              TextButton(
                onPressed: totalHours <= 0
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: Text(
                  '設定する',
                  style: TextStyle(
                    color: totalHours > 0
                        ? const Color(0xFFF97316)
                        : const Color(0xFF444444),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true) return;

    try {
      await _api.setBlockUntil(days, hours);
      await _poll();
      final label = days > 0 && hours > 0
          ? '$days日$hours時間'
          : days > 0
              ? '$days日間'
              : '$hours時間';
      messenger.showSnackBar(SnackBar(
        content: Text('$labelの期間ブロックを設定しました'),
        backgroundColor: const Color(0xFF1A1A1A),
      ));
    } catch (e) {
      messenger.showSnackBar(
        const SnackBar(content: Text('エラーが発生しました')),
      );
    }
  }

  // 期間ブロックをキャンセルする
  Future<void> _cancelBlockUntil() async {
    try {
      await _api.cancelBlockUntil();
      await _poll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('エラーが発生しました')),
        );
      }
    }
  }

  Future<void> _openAppPicker() async {
    final plan = _config?['plan'] as String? ?? 'free';
    final locked = _config != null && _shouldBlock(_config!);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(plan: plan, locked: locked),
      ),
    );
    await _poll();
  }

  Future<void> _openUpgradePage() async {
    // プラン一覧を取得してボトムシートで選択させる
    List<Map<String, dynamic>> plans = [];
    try {
      plans = await _api.fetchMobilePlans();
    } catch (_) {}

    if (!mounted) return;

    if (plans.isEmpty) {
      // プラン情報取得失敗時はデフォルト月額で直接開く
      _launchCheckout('monthly');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlanSheet(plans: plans, onSelect: _launchCheckout),
    );
  }

  Future<void> _launchCheckout(String planId) async {
    try {
      final url = await _api.fetchMobileCheckoutUrl(plan: planId);
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('課金ページを開けませんでした'),
            backgroundColor: Color(0xFF1A1A1A),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildHomeTab(),
          RankingScreen(
            api: _api,
            plan: _config?['plan'] as String? ?? 'free',
            onUpgrade: _openUpgradePage,
          ),
          LogsScreen(api: _api),
          // ブロック設定タブ：サイトブロック＋アプリブロックをまとめて管理する
          BlockSettingsScreen(
            api: _api,
            config: _config,
            onRefresh: _poll,
            onOpenAppPicker: _openAppPicker,
          ),
          _buildSettingsTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        backgroundColor: const Color(0xFF111111),
        selectedItemColor: const Color(0xFFF97316),
        unselectedItemColor: const Color(0xFF555555),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'ホーム',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.leaderboard_outlined),
            activeIcon: Icon(Icons.leaderboard),
            label: 'ランキング',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'ログ',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shield_outlined),
            activeIcon: Icon(Icons.shield),
            label: 'ブロック設定',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: '設定',
          ),
        ],
      ),
    );
  }

  // 期間ブロックが現在有効かどうかを返す（emergency中も有効とみなす）
  bool _isBlockUntilActive(Map<String, dynamic>? config) {
    final blockUntil = config?['block_until'] as String?;
    if (blockUntil == null || blockUntil.isEmpty) return false;
    try {
      return DateTime.now().isBefore(DateTime.parse(blockUntil));
    } catch (_) {
      return false;
    }
  }

  // 緊急解除の残り秒数を "残りX時間Y分" 形式に整形する
  String _formatEmergencyRemaining(int secs) {
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    if (h > 0) return '残り${h}時間${m}分';
    return '残り${m}分';
  }

  // 期間ブロックの終了日時を "MM/DD HH:mm まで" 形式に整形する
  String _formatBlockUntil(String isoStr) {
    try {
      final dt = DateTime.parse(isoStr);
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} まで';
    } catch (_) {
      return '';
    }
  }

  Widget _buildHomeTab() {
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
    final blockUntilActive = _isBlockUntilActive(_config);
    final blockUntilStr    = _config?['block_until'] as String? ?? '';

    return SafeArea(
        child: RefreshIndicator(
          onRefresh: _poll,
          color: const Color(0xFFF97316),
          backgroundColor: const Color(0xFF1A1A1A),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // ヘッダー
              const Text('Toxov',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1)),
              const SizedBox(height: 16),

              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(color: Color(0xFFF97316)),
                  ),
                )
              else if (_error != null)
                _card(child: Column(children: [
                  Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B))),
                  TextButton(
                      onPressed: _poll,
                      child: const Text('再試行',
                          style: TextStyle(color: Color(0xFFF97316)))),
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
                  Text(
                      _config?['streak_comment'] as String? ?? '継続中',
                      style: const TextStyle(color: Color(0xFF555555), fontSize: 12)),
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
                        if (emergency && _config?['emergency_remaining_secs'] != null)
                          Text(
                            _formatEmergencyRemaining(
                                (_config!['emergency_remaining_secs'] as num).toInt()),
                            style: const TextStyle(
                                color: Color(0xFFFFA94D), fontSize: 12),
                          )
                        else if (_config != null)
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

                // ── 期間ブロックカード ──
                _buildBlockUntilCard(blockUntilActive, blockUntilStr),
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
                    Icon(
                      shouldBlockNow ? Icons.lock_outline : Icons.chevron_right,
                      color: shouldBlockNow
                          ? const Color(0xFFF97316)
                          : const Color(0xFF555555),
                      size: 20,
                    ),
                  ])),
                ),
                const SizedBox(height: 8),

                // ── ポイント・ランクカード ──
                GestureDetector(
                  onTap: () => setState(() => _tabIndex = 1),
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
                                        color: Color(0xFFF97316),
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
                                Color(0xFFF97316)),
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
                  onTap: () => setState(() => _tabIndex = 2),
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
                                color: Color(0xFFF97316), fontSize: 13)),
                        Icon(Icons.chevron_right,
                            color: Color(0xFFF97316), size: 18),
                      ]),
                    ],
                  )),
                ),
                const SizedBox(height: 20),

                // ── 緊急解除ボタン（ブロック時間内かつ未解除のときのみ表示）──
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

                // ── ブロックに戻るボタン（緊急解除中のみ表示）──
                if (emergency)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _resumeLoading ? null : _resumeEmergency,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF4ADE80),
                        side: const BorderSide(color: Color(0xFF1A3A1A)),
                        backgroundColor: const Color(0xFF0A1A0A),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _resumeLoading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF4ADE80)))
                          : const Text('ブロックに戻る',
                              style: TextStyle(fontSize: 13)),
                    ),
                  ),
              ],
            ],
          ),
        ),
    );
  }

  Future<void> _adminSetPlan(String plan) async {
    try {
      await _api.adminSetPlan(plan);
      await _poll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('プランを $plan に変更しました'),
            backgroundColor: const Color(0xFF1A1A1A),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('プラン変更に失敗しました')),
        );
      }
    }
  }

  Widget _buildSettingsTab() {
    final isPremium = (_config?['plan'] as String?) == 'premium';
    final isAdmin   = (_config?['role'] as String?) == 'admin';
    final username  = _config?['username'] as String?;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          const Text('設定',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          const SizedBox(height: 24),

          // プランカード
          _card(child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isPremium
                      ? const Color(0xFFF97316).withValues(alpha: 0.15)
                      : const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isPremium ? Icons.workspace_premium : Icons.lock_outline,
                  color: isPremium
                      ? const Color(0xFFF97316)
                      : const Color(0xFF555555),
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPremium ? 'Premium' : '無料プラン',
                      style: TextStyle(
                          color: isPremium
                              ? const Color(0xFFF97316)
                              : Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                    Text(
                      isPremium
                          ? 'アプリブロック無制限・シールド使用可'
                          : 'アプリブロックは3個まで',
                      style: const TextStyle(
                          color: Color(0xFF555555), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          )),
          const SizedBox(height: 12),

          // アップグレード or 管理ボタン
          if (!isPremium)
            GestureDetector(
              onTap: _openUpgradePage,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2A1500), Color(0xFF1A1A00)],
                  ),
                  border: Border.all(
                      color: const Color(0xFFF97316).withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(children: [
                  const Text('⚡', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Premium にアップグレード',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                        SizedBox(height: 3),
                        Text('7日間無料トライアル付き',
                            style: TextStyle(
                                color: Color(0xFF888888), fontSize: 12)),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios,
                      color: Color(0xFFF97316), size: 16),
                ]),
              ),
            ),
          const SizedBox(height: 24),

          // ── Admin専用：プラン切り替え・デバッグ ──
          if (isAdmin) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                border: Border.all(color: const Color(0xFF333333)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.admin_panel_settings,
                        color: Color(0xFF888888), size: 15),
                    SizedBox(width: 6),
                    Text('Admin — プラン切り替え',
                        style: TextStyle(
                            color: Color(0xFF888888),
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: isPremium
                            ? () => _adminSetPlan('free')
                            : null,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF888888),
                          side: BorderSide(
                              color: isPremium
                                  ? const Color(0xFF444444)
                                  : const Color(0xFF222222)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Free に変更',
                            style: TextStyle(fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: !isPremium
                            ? () => _adminSetPlan('premium')
                            : null,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFF97316),
                          side: BorderSide(
                              color: !isPremium
                                  ? const Color(0xFFF97316)
                                      .withValues(alpha: 0.5)
                                  : const Color(0xFF222222)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Premium に変更',
                            style: TextStyle(fontSize: 13)),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  const Divider(color: Color(0xFF222222), height: 1),
                  const SizedBox(height: 16),
                  const Row(children: [
                    Icon(Icons.bug_report_outlined,
                        color: Color(0xFF888888), size: 15),
                    SizedBox(width: 6),
                    Text('Admin — デバッグ',
                        style: TextStyle(
                            color: Color(0xFF888888),
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 12),
                  // オンボーディングをリセットして最初のガイド画面に戻る
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        await StorageService.clearOnboardingDone();
                        if (context.mounted) {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) => OnboardingScreen(
                                  configUrl: widget.configUrl),
                            ),
                          );
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF888888),
                        side: const BorderSide(color: Color(0xFF333333)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('オンボーディングをリセット',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ログアウト
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF888888),
                side: const BorderSide(color: Color(0xFF2A2A2A)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('接続解除', style: TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  // 期間ブロック状態カード：有効中はキャンセルボタン付き、無効中は設定ボタンを表示する
  Widget _buildBlockUntilCard(bool active, String blockUntilStr) {
    if (active) {
      return _card(child: Row(children: [
        _dot(const Color(0xFFFF6B6B)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('期間ブロック中',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
            Text(_formatBlockUntil(blockUntilStr),
                style: const TextStyle(color: Color(0xFF555555), fontSize: 12)),
          ]),
        ),
        GestureDetector(
          onTap: _cancelBlockUntil,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1A1A),
              border: Border.all(color: const Color(0xFF3A2A2A)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('解除',
                style: TextStyle(color: Color(0xFFFF6B6B), fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]));
    }
    return GestureDetector(
      onTap: _showBlockUntilDialog,
      child: _card(child: Row(children: [
        const Icon(Icons.lock_clock_outlined, color: Color(0xFF555555), size: 18),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('期間ブロックを設定',
              style: TextStyle(color: Color(0xFF888888), fontSize: 14)),
        ),
        const Icon(Icons.add, color: Color(0xFF555555), size: 18),
      ])),
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

// プラン選択ボトムシート
class _PlanSheet extends StatelessWidget {
  final List<Map<String, dynamic>> plans;
  final void Function(String planId) onSelect;

  const _PlanSheet({required this.plans, required this.onSelect});

  String _formatAmount(Map<String, dynamic> plan) {
    final amount   = plan['amount'] as int? ?? 0;
    final currency = (plan['currency'] as String? ?? 'jpy').toLowerCase();
    final interval = plan['interval'] as String?;
    final amountStr = currency == 'jpy'
        ? '¥${_formatNumber(amount)}'
        : '\$${(amount / 100).toStringAsFixed(0)}';
    final suffix = interval == 'month' ? '/月' : interval == 'year' ? '/年' : '';
    return '$amountStr$suffix';
  }

  String _formatNumber(int n) {
    // 3桁カンマ区切り
    return n.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('料金プランを選択',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('7日間無料トライアル付き',
              style: TextStyle(color: Color(0xFF888888), fontSize: 13)),
          const SizedBox(height: 20),
          ...plans.map((plan) => _planTile(context, plan)),
        ],
      ),
    );
  }

  Widget _planTile(BuildContext context, Map<String, dynamic> plan) {
    final planId = plan['id'] as String? ?? '';
    final label  = plan['label'] as String? ?? '';

    return GestureDetector(
      onTap: () {
        Navigator.pop(context);
        onSelect(planId);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          // ラベル
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          // 金額
          Text(_formatAmount(plan),
              style: const TextStyle(
                  color: Color(0xFFF97316),
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          const Icon(Icons.arrow_forward_ios,
              color: Color(0xFF555555), size: 13),
        ]),
      ),
    );
  }
}
