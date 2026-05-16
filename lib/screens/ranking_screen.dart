import 'package:flutter/material.dart';
import '../services/api_service.dart';

class RankingScreen extends StatefulWidget {
  final ApiService api;
  const RankingScreen({super.key, required this.api});

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _ranking = [];
  Map<String, dynamic>? _rankPos;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final stats = await widget.api.fetchStats();
      setState(() {
        _ranking = (stats['ranking'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _rankPos = Map<String, dynamic>.from(
            stats['rank_position'] as Map? ?? {});
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = 'データを取得できません'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        foregroundColor: Colors.white,
        title: const Text('シーズンランキング',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF4DABF7)))
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!,
                        style: const TextStyle(color: Color(0xFF888888))),
                    const SizedBox(height: 12),
                    TextButton(
                        onPressed: _load,
                        child: const Text('再試行',
                            style: TextStyle(color: Color(0xFF4DABF7)))),
                  ]))
              : RefreshIndicator(
                  onRefresh: _load,
                  color: const Color(0xFF4DABF7),
                  backgroundColor: const Color(0xFF1A1A1A),
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      // 自分の順位カード
                      if (_rankPos != null && _rankPos!['rank_position'] != null)
                        _myRankCard(),
                      const SizedBox(height: 20),
                      // ランキングリスト
                      ..._ranking.asMap().entries.map((e) {
                        final i    = e.key;
                        final user = e.value;
                        return _rankRow(i + 1, user);
                      }),
                    ],
                  ),
                ),
    );
  }

  Widget _myRankCard() {
    final pos     = _rankPos!['rank_position'] as int;
    final total   = _rankPos!['total_users'] as int;
    final percent = _rankPos!['top_percent'] as int?;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: const Color(0xFF4DABF7).withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('あなたの順位',
                style: TextStyle(color: Color(0xFF888888), fontSize: 12)),
            const SizedBox(height: 4),
            RichText(
              text: TextSpan(children: [
                TextSpan(
                  text: '$pos',
                  style: const TextStyle(
                      color: Color(0xFF4DABF7),
                      fontSize: 32,
                      fontWeight: FontWeight.w800),
                ),
                TextSpan(
                  text: ' / $total 位',
                  style: const TextStyle(
                      color: Color(0xFF888888), fontSize: 16),
                ),
              ]),
            ),
          ]),
          if (percent != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF4DABF7).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: const Color(0xFF4DABF7).withValues(alpha: 0.3)),
              ),
              child: Text(
                '上位 $percent%',
                style: const TextStyle(
                    color: Color(0xFF4DABF7),
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rankRow(int pos, Map<String, dynamic> user) {
    final name = user['username'] as String? ?? '—';
    final pts  = user['season_points'] as int? ?? 0;
    final medal = pos == 1
        ? '🥇'
        : pos == 2
            ? '🥈'
            : pos == 3
                ? '🥉'
                : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: const Color(0xFF1E1E1E), width: 1),
        ),
      ),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: medal != null
              ? Text(medal, style: const TextStyle(fontSize: 18))
              : Text(
                  '$pos',
                  style: const TextStyle(
                      color: Color(0xFF555555),
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            name,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500),
          ),
        ),
        Text(
          '$pts pt',
          style: const TextStyle(
              color: Color(0xFF4DABF7),
              fontSize: 14,
              fontWeight: FontWeight.w700),
        ),
      ]),
    );
  }
}
