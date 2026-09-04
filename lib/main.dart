import 'package:flutter/material.dart';
import 'screens/home_screen.dart';   // 같은 lib 폴더 기준 상대 경로

void main() {
  runApp(const MoipzApp());
}

// 앱의 가장 바깥 껍데기 — 이제 이 파일은 "앱 진입점" 역할만 한다
class MoipzApp extends StatelessWidget {
  const MoipzApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MOIP-Z',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF534AB7),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const HomeScreen(),   // home_screen.dart에서 import한 클래스
    );
  }
}