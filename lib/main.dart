import 'package:flutter/material.dart';
import 'services/storage_service.dart';
import 'screens/setup_screen.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ToxovApp());
}

class ToxovApp extends StatelessWidget {
  const ToxovApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Toxov',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4DABF7),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
      ),
      // 保存済みURLがあればホーム画面、なければセットアップ画面を表示する
      home: const _StartupGate(),
    );
  }
}

class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  @override
  void initState() {
    super.initState();
    _navigate();
  }

  Future<void> _navigate() async {
    final url = await StorageService.getUrl();
    if (!mounted) return;
    if (url != null && url.isNotEmpty) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => HomeScreen(configUrl: url)),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const SetupScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // URLの読み込み中にスプラッシュとして表示する
    return const Scaffold(
      backgroundColor: Color(0xFF0F0F0F),
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFF4DABF7)),
      ),
    );
  }
}
