import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ══════════════════════════════════════════════════════════════
// FittingHistoryScreen — 피팅 사진 모음
//  shared_preferences 'fitting_history'를 최신순으로 표시
//  각 항목 구조: { date(ISO), imagePath, clothNames(list) }
//   - 결과 이미지(Image.file) + 날짜 + 선택했던 옷 이름
//   - 길게 누르면 삭제 (파일 + 리스트에서 제거)
//   - 비어있으면 안내
// ══════════════════════════════════════════════════════════════

class FittingHistoryScreen extends StatefulWidget {
  const FittingHistoryScreen({super.key});

  @override
  State<FittingHistoryScreen> createState() => _FittingHistoryScreenState();
}

class _FittingHistoryScreenState extends State<FittingHistoryScreen> {
  static const String _prefsKey = 'fitting_history';
  static const Color _brand = Color(0xFF534AB7);

  bool _loading = true;
  // 최신순으로 정렬된 항목 (각 항목 {date, imagePath, clothNames})
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  // ── 저장된 피팅 기록 불러오기 (최신순) ───────
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    List<Map<String, dynamic>> loaded = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        loaded = decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {/* 손상된 JSON이면 빈 목록 */}
    }
    // 저장은 append 순서(과거→최신)이므로 뒤집어서 최신순으로
    loaded = loaded.reversed.toList();

    if (!mounted) return;
    setState(() {
      _items = loaded;
      _loading = false;
    });
  }

  // ── 항목 삭제 (파일 + 리스트) ────────────────
  //   _items는 최신순(역순)이므로, 저장 원본에서 동일 항목을 찾아 제거 후 다시 저장
  Future<void> _deleteItem(Map<String, dynamic> item) async {
    // 1) 이미지 파일 삭제 (실패해도 무시)
    final imagePath = (item['imagePath'] ?? '').toString();
    if (imagePath.isNotEmpty) {
      try {
        final f = File(imagePath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {/* 파일 삭제 실패는 치명적이지 않음 */}
    }

    // 2) prefs 원본에서 제거 후 재저장
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    List<dynamic> history = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        history = jsonDecode(raw) as List<dynamic>;
      } catch (_) {/* 무시 */}
    }
    // date+imagePath로 동일 항목 식별해 제거
    history.removeWhere((e) =>
        e is Map &&
        e['date'] == item['date'] &&
        e['imagePath'] == item['imagePath']);
    await prefs.setString(_prefsKey, jsonEncode(history));

    // 3) 화면 갱신
    if (!mounted) return;
    setState(() {
      _items.remove(item);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('삭제되었습니다'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  // 삭제 확인 다이얼로그
  Future<void> _confirmDelete(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('피팅 사진 삭제'),
        content: const Text('이 피팅 사진을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteItem(item);
  }

  // ISO 문자열 → 읽기 좋은 포맷 (yyyy.MM.dd HH:mm)
  String _formatDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}.${two(d.month)}.${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  // clothNames(list) → '셔츠, 청바지' 형태
  String _clothNamesOf(Map<String, dynamic> item) {
    final raw = item['clothNames'];
    if (raw is List) {
      return raw.map((e) => e.toString()).where((s) => s.isNotEmpty).join(', ');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: Colors.black87),
        title: const Text(
          '피팅 사진 모음',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
            fontSize: 17,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: _brand),
      );
    }

    if (_items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checkroom, size: 56, color: Colors.black26),
            SizedBox(height: 12),
            Text('아직 저장된 피팅이 없어요',
                style: TextStyle(fontSize: 14, color: Colors.black54)),
            SizedBox(height: 4),
            Text('가상 피팅에서 결과를 저장하면 여기에 모여요',
                style: TextStyle(fontSize: 11, color: Colors.black38)),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.62,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) => _buildHistoryCard(_items[index]),
    );
  }

  Widget _buildHistoryCard(Map<String, dynamic> item) {
    final imagePath = (item['imagePath'] ?? '').toString();
    final hasImage = imagePath.isNotEmpty && File(imagePath).existsSync();
    final clothNames = _clothNamesOf(item);

    // 길게 누르기 + 우측 상단 삭제 아이콘 둘 다로 삭제 가능
    return GestureDetector(
      onLongPress: () => _confirmDelete(item),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF1EFE8),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 결과 이미지
                Expanded(
                  child: Container(
                    width: double.infinity,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: hasImage
                        ? Image.file(
                            File(imagePath),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.black26),
                          )
                        : const Icon(Icons.broken_image_outlined,
                            size: 36, color: Colors.black26),
                  ),
                ),
                const SizedBox(height: 8),
                // 날짜
                Text(
                  _formatDate((item['date'] ?? '').toString()),
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF534AB7)),
                ),
                const SizedBox(height: 2),
                // 선택했던 옷 이름
                Text(
                  clothNames.isEmpty ? '옷 정보 없음' : clothNames,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),

          // 우측 상단 삭제(휴지통) 아이콘 버튼
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _confirmDelete(item),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.delete_outline,
                      size: 18, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
