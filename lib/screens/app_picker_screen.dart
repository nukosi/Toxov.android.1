import 'package:flutter/material.dart';
import '../services/app_blocker_bridge.dart';
import '../services/storage_service.dart';

// ブロックするAndroidアプリを選択する画面（無料プランは3個まで）
class AppPickerScreen extends StatefulWidget {
  final String plan;
  const AppPickerScreen({super.key, this.plan = 'free'});

  @override
  State<AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppPickerScreenState extends State<AppPickerScreen> {
  List<Map<String, String>> _allApps = [];
  Set<String> _selectedPackages = {};
  bool _loading = true;
  bool _hasPermission = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final hasPerm = await AppBlockerBridge.hasUsagePermission();
    if (!hasPerm) {
      setState(() {
        _hasPermission = false;
        _loading = false;
      });
      return;
    }

    final apps = await AppBlockerBridge.getInstalledApps();
    final saved = await StorageService.getAndroidPackages();

    // アプリ名でソート
    apps.sort((a, b) => (a['appName'] ?? '').compareTo(b['appName'] ?? ''));

    setState(() {
      _allApps = apps;
      _selectedPackages = saved.toSet();
      _hasPermission = true;
      _loading = false;
    });
  }

  Future<void> _requestPermission() async {
    await AppBlockerBridge.requestUsagePermission();
    // 設定画面から戻ってきたら再確認
    await Future.delayed(const Duration(milliseconds: 500));
    await _init();
  }

  static const _freeAppLimit = 3;

  Future<void> _toggleApp(String packageName) async {
    // 無料プランで上限に達している場合は追加を拒否してアップグレードを促す
    if (!_selectedPackages.contains(packageName) &&
        widget.plan == 'free' &&
        _selectedPackages.length >= _freeAppLimit) {
      _showUpgradeDialog();
      return;
    }
    setState(() {
      if (_selectedPackages.contains(packageName)) {
        _selectedPackages.remove(packageName);
      } else {
        _selectedPackages.add(packageName);
      }
    });
    await StorageService.saveAndroidPackages(_selectedPackages.toList());
  }

  void _showUpgradeDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('上限に達しました',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
          '無料プランではアプリブロックは3個までです。\nPremiumにアップグレードすると無制限に追加できます。',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる',
                style: TextStyle(color: Color(0xFF555555))),
          ),
        ],
      ),
    );
  }

  List<Map<String, String>> get _filteredApps {
    if (_search.isEmpty) return _allApps;
    final q = _search.toLowerCase();
    return _allApps
        .where((a) =>
            (a['appName'] ?? '').toLowerCase().contains(q) ||
            (a['packageName'] ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        foregroundColor: Colors.white,
        title: const Text(
          'ブロックするアプリ',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        actions: [
          if (_selectedPackages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  widget.plan == 'free'
                      ? '${_selectedPackages.length} / $_freeAppLimit 個'
                      : '${_selectedPackages.length}個選択中',
                  style: TextStyle(
                    color: widget.plan == 'free' &&
                            _selectedPackages.length >= _freeAppLimit
                        ? const Color(0xFFFF6B6B)
                        : const Color(0xFF4DABF7),
                    fontSize: 13,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4DABF7)),
            )
          : !_hasPermission
              ? _permissionView()
              : Column(
                  children: [
                    _searchBar(),
                    Expanded(child: _appList()),
                  ],
                ),
    );
  }

  Widget _permissionView() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '使用状況アクセスの許可が必要です',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'アプリブロック機能を使うには、「使用状況へのアクセス」を許可してください。\n\n設定 → アプリ → 特別なアプリアクセス → 使用状況へのアクセス → Toxov',
            style: TextStyle(color: Color(0xFF888888), fontSize: 14, height: 1.6),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _requestPermission,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4DABF7),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                '設定を開く',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        style: const TextStyle(color: Colors.white, fontSize: 14),
        onChanged: (v) => setState(() => _search = v),
        decoration: InputDecoration(
          hintText: 'アプリを検索',
          hintStyle: const TextStyle(color: Color(0xFF444444)),
          prefixIcon:
              const Icon(Icons.search, color: Color(0xFF555555), size: 20),
          filled: true,
          fillColor: const Color(0xFF1A1A1A),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF4DABF7)),
          ),
        ),
      ),
    );
  }

  Widget _appList() {
    final apps = _filteredApps;
    if (apps.isEmpty) {
      return const Center(
        child: Text(
          'アプリが見つかりません',
          style: TextStyle(color: Color(0xFF555555)),
        ),
      );
    }
    return ListView.builder(
      itemCount: apps.length,
      itemBuilder: (context, i) {
        final app = apps[i];
        final pkg = app['packageName']!;
        final name = app['appName']!;
        final selected = _selectedPackages.contains(pkg);
        return InkWell(
          onTap: () => _toggleApp(pkg),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: const Color(0xFF1E1E1E), width: 1),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        pkg,
                        style: const TextStyle(
                          color: Color(0xFF555555),
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? const Color(0xFF4DABF7)
                        : const Color(0xFF2A2A2A),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF4DABF7)
                          : const Color(0xFF444444),
                    ),
                  ),
                  child: selected
                      ? const Icon(Icons.check, size: 14, color: Colors.black)
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
