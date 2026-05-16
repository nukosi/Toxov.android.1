import 'package:flutter/material.dart';
import '../services/api_service.dart';

class LogsScreen extends StatefulWidget {
  final ApiService api;
  const LogsScreen({super.key, required this.api});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _logs = [];

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
        _logs = (stats['logs'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
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
        title: const Text('ログ履歴',
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
              : _logs.isEmpty
                  ? const Center(
                      child: Text('まだログがありません',
                          style: TextStyle(color: Color(0xFF555555))))
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: const Color(0xFF4DABF7),
                      backgroundColor: const Color(0xFF1A1A1A),
                      child: ListView.builder(
                        itemCount: _logs.length,
                        itemBuilder: (context, i) => _logRow(_logs[i]),
                      ),
                    ),
    );
  }

  Widget _logRow(Map<String, dynamic> log) {
    final event = log['event'] as String? ?? '';
    final time  = log['created_at'] as String? ?? '';
    final (emoji, label, color) = _eventInfo(event);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: const Color(0xFF1E1E1E), width: 1),
        ),
      ),
      child: Row(children: [
        Text(emoji, style: const TextStyle(fontSize: 18)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: color, fontSize: 14, fontWeight: FontWeight.w500)),
        ),
        Text(time,
            style: const TextStyle(color: Color(0xFF555555), fontSize: 12)),
      ]),
    );
  }

  (String, String, Color) _eventInfo(String event) => switch (event) {
        'block_start'       => ('🔴', 'ブロック開始',   const Color(0xFFFF6B6B)),
        'block_end'         => ('🟢', 'ブロック終了',   const Color(0xFF69DB7C)),
        'emergency_unblock' => ('🟡', '緊急解除',       const Color(0xFFFFA94D)),
        'shield_used'       => ('🛡', 'シールド使用',  const Color(0xFF4DABF7)),
        _                   => ('⚪', event,            const Color(0xFF888888)),
      };
}
