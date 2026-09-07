import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/gemini_service.dart';
import 'fitting_history_screen.dart';

// ══════════════════════════════════════════════════════════════
// WardrobeScreen — 내 옷장 화면
// FAB 2개(앨범/카메라) → 사진 선택
//   → ① 이미지를 앱 documents 폴더에 영구 복사(path_provider)  ← 분석보다 먼저!
//   → ② Gemini analyzeClothing 분석 시도 (실패해도 앱이 죽지 않음)
//        성공: 분석 결과로 항목 생성
//        실패: 수동 입력 다이얼로그로 fallback (이미지는 이미 저장됨)
//   → ③ shared_preferences에 옷 목록 저장(key 'wardrobe_clothes')
// 옷 항목 구조: {category, color, type, season, imagePath}
// ══════════════════════════════════════════════════════════════

class WardrobeScreen extends StatefulWidget {
  const WardrobeScreen({super.key});

  @override
  State<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends State<WardrobeScreen> {
  // shared_preferences 저장 키
  static const String _prefsKey = 'wardrobe_clothes';

  final ImagePicker _picker = ImagePicker();

  // 분석 중 여부 (로딩 오버레이 표시용)
  bool _analyzing = false;

  int _selectedCategory = 0;
  final List<String> _categories = ['전체', '상의', '하의', '아우터', '신발'];

  // 옷 데이터 — 항목 구조 {category, color, type, season, imagePath}
  // imagePath가 빈 문자열이거나 파일이 없으면 기본 아이콘 표시
  // (아래 더미 데이터는 첫 실행 시에만 보이는 시드 값. prefs에 저장된 값이 있으면 그것으로 대체)
  final List<Map<String, String>> _clothes = [
    {'category': '아우터', 'color': '베이지', 'type': '베이지 코트', 'season': '겨울', 'imagePath': ''},
    {'category': '신발', 'color': '화이트', 'type': '스니커즈', 'season': '사계절', 'imagePath': ''},
  ];

  @override
  void initState() {
    super.initState();
    _loadClothes(); // 저장된 옷 목록 불러오기
  }

  // ── 저장된 옷 목록 불러오기 ──────────────────────────
  Future<void> _loadClothes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return; // 저장된 값 없으면 더미 시드 그대로 사용

    final List<dynamic> decoded = jsonDecode(raw);
    if (!mounted) return;
    setState(() {
      _clothes
        ..clear()
        ..addAll(decoded.map((e) => Map<String, String>.from(e as Map)));
    });
  }

  // ── 옷 목록을 shared_preferences에 저장 ───────────────
  Future<void> _saveClothes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_clothes));
  }

  // ── 선택한 사진을 앱 documents 폴더로 영구 복사 ───────
  // 갤러리/카메라가 주는 임시 경로는 캐시 정리 시 사라지므로 복사해서 보존
  Future<String> _saveImagePermanently(String sourcePath) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final ext = sourcePath.contains('.')
        ? sourcePath.substring(sourcePath.lastIndexOf('.'))
        : '.jpg';
    final fileName = 'cloth_${DateTime.now().millisecondsSinceEpoch}$ext';
    final newPath = '${docsDir.path}${Platform.pathSeparator}$fileName';
    await File(sourcePath).copy(newPath);
    return newPath;
  }

  // ── 사진 선택 → 영구 저장 → 분석 → 저장 (앨범/카메라 공통) ──
  Future<void> _addClothing(ImageSource source) async {
    // 1) 사진 선택 (앨범 또는 카메라)
    final XFile? picked = await _picker.pickImage(
      source: source,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
      preferredCameraDevice: CameraDevice.rear, // 카메라일 때만 적용됨
    );
    if (picked == null) return; // 선택/촬영 취소 시 종료

    setState(() => _analyzing = true);

    // 2) ★ 이미지를 먼저 영구 저장 — 분석 성공 여부와 무관하게 사진은 항상 보존
    String savedPath;
    try {
      savedPath = await _saveImagePermanently(picked.path);
    } catch (e) {
      setState(() => _analyzing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('이미지 저장 실패: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return; // 이미지조차 저장 못 하면 더 진행할 의미가 없음
    }

    // 3) Gemini 분석 시도 — 네이티브 로드 실패 등 어떤 예외가 나도 앱이 죽지 않도록 격리
    Map<String, dynamic>? parsed;
    String? analyzeError;
    try {
      final imageBytes = await File(savedPath).readAsBytes();
      parsed = await GeminiService.instance.analyzeClothing(imageBytes);
    } catch (e) {
      analyzeError = e.toString();
    }

    setState(() => _analyzing = false);

    if (parsed != null) {
      // 4-a) 분석 성공 → 분석 결과로 항목 생성
      final newItem = <String, String>{
        'category': parsed['category']?.toString() ?? '기타',
        'color': parsed['color']?.toString() ?? '',
        'type': parsed['type']?.toString() ?? '이름 없음',
        'season': parsed['season']?.toString() ?? '사계절',
        'imagePath': savedPath,
      };
      setState(() => _clothes.add(newItem));
      await _saveClothes();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"${newItem['type']}" 추가됨'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } else {
      // 4-b) 분석 실패 → 이미지는 이미 저장됨. 수동 입력으로 fallback
      await _addManually(savedPath, analyzeError);
    }
  }

  // ── 분석 실패 시 직접 카테고리/이름/색상 입력 ─────────
  // 다이얼로그 결과와 무관하게 이미지(savedPath)는 항상 저장됨
  Future<void> _addManually(String savedPath, String? analyzeError) async {
    final typeCtrl = TextEditingController();
    final colorCtrl = TextEditingController();
    final inputCategories = ['상의', '하의', '아우터', '신발', '기타'];
    String category = '기타';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('AI 분석 실패 — 직접 입력'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 저장된 사진 미리보기 (이미지는 이미 보존됨을 시각적으로 확인)
                if (File(savedPath).existsSync())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(savedPath),
                          height: 120, fit: BoxFit.cover),
                    ),
                  ),
                if (analyzeError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '오류: $analyzeError',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.redAccent),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                TextField(
                  controller: typeCtrl,
                  decoration:
                      const InputDecoration(labelText: '옷 이름/종류'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(labelText: '카테고리'),
                  items: inputCategories
                      .map((c) =>
                          DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) =>
                      setDialogState(() => category = v ?? '기타'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: colorCtrl,
                  decoration: const InputDecoration(labelText: '색상'),
                ),
              ],
            ),
          ),
          actions: [
            // '건너뛰기'든 '저장'이든 항목은 추가됨 (이미지 보존이 목적)
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('건너뛰기'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );

    // 입력값(없으면 기본값)으로 항목 생성 — imagePath는 항상 savedPath
    final newItem = <String, String>{
      'category': category,
      'color': colorCtrl.text.trim(),
      'type': typeCtrl.text.trim().isEmpty ? '미분류 옷' : typeCtrl.text.trim(),
      'season': '사계절',
      'imagePath': savedPath,
    };
    setState(() => _clothes.add(newItem));
    await _saveClothes();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${newItem['type']}" 추가됨 (직접 입력)'),
          duration: const Duration(seconds: 1),
        ),
      );
    }

    typeCtrl.dispose();
    colorCtrl.dispose();
  }

  // ── 삭제 확인 다이얼로그 → 확인 시 삭제 ─────────────────
  Future<void> _confirmDelete(Map<String, String> cloth) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('옷 삭제'),
        content: const Text('이 옷을 삭제할까요?'),
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
    if (confirmed != true) return;
    await _deleteClothing(cloth);
  }

  // ── 옷 삭제 ──────────────────────────────────────────
  //  (a) prefs 목록에서 제거 후 다시 저장
  //  (b) imagePath 파일도 documents 폴더에서 삭제 (실패해도 앱은 안 죽게 try/catch)
  //  (c) setState로 즉시 화면 갱신 → 카드 사라지고 '총 N벌' 카운트 감소
  Future<void> _deleteClothing(Map<String, String> cloth) async {
    // (b) 저장됐던 이미지 파일 삭제 — 더미 시드는 imagePath가 비어 있으니 건너뜀
    final imagePath = cloth['imagePath'] ?? '';
    if (imagePath.isNotEmpty) {
      try {
        final file = File(imagePath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (e) {
        // 파일 삭제 실패는 치명적이지 않으므로 로그만 남기고 진행
        debugPrint('이미지 파일 삭제 실패: $e');
      }
    }

    // (c) 목록에서 제거 → 화면 즉시 갱신 ('총 N벌'도 _clothes.length라 자동 감소)
    //     filteredClothes 항목은 _clothes 내부 Map과 동일 참조라 remove로 정확히 제거됨
    setState(() => _clothes.remove(cloth));

    // (a) 변경된 목록을 다시 저장
    await _saveClothes();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('옷이 삭제되었습니다'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredClothes = _selectedCategory == 0
        ? _clothes
        : _clothes
            .where((c) => c['category'] == _categories[_selectedCategory])
            .toList();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: Colors.black87),
        title: const Text('내 옷장',
            style: TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w600,
                fontSize: 17)),
        // 우측 상단: 피팅 사진 모음으로 이동
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const FittingHistoryScreen()),
              );
            },
            icon: const Icon(Icons.photo_library_outlined,
                size: 18, color: Color(0xFF534AB7)),
            label: const Text('피팅 사진',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF534AB7))),
          ),
        ],
      ),

      // Stack으로 감싸서 분석 중 로딩 오버레이를 위에 띄움
      body: Stack(
        children: [
          // ── 기존 옷장 내용 ──────────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('신민종님의 옷장',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
              ),
              // 옷 개수 — 추가될 때마다 자동 갱신
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Text('총 ${_clothes.length}벌',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w600)),
              ),

              // 카테고리 탭
              SizedBox(
                height: 40,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _categories.length,
                  itemBuilder: (context, index) {
                    final isSelected = index == _selectedCategory;
                    return GestureDetector(
                      onTap: () =>
                          setState(() => _selectedCategory = index),
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF534AB7)
                              : const Color(0xFFF1EFE8),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Center(
                          child: Text(_categories[index],
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.black87)),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 16),

              // 옷 그리드
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: filteredClothes.length,
                  itemBuilder: (context, index) =>
                      _buildClothCard(filteredClothes[index]),
                ),
              ),
            ],
          ),

          // ── 분석 중 로딩 오버레이 ────────────
          if (_analyzing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text('AI가 옷을 분석하고 있어요...',
                        style:
                            TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
            ),
        ],
      ),

      // ── FAB 2개: 위=앨범, 아래=카메라 (heroTag를 다르게 줘서 충돌 방지) ──
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 앨범 버튼 → 갤러리에서 선택
          FloatingActionButton(
            heroTag: 'fab_gallery',
            backgroundColor: const Color(0xFF534AB7),
            tooltip: '앨범에서 선택',
            onPressed:
                _analyzing ? null : () => _addClothing(ImageSource.gallery),
            child: const Icon(Icons.photo_library, color: Colors.white),
          ),
          const SizedBox(height: 12),
          // 카메라 버튼 → 후면 카메라로 촬영
          FloatingActionButton(
            heroTag: 'fab_camera',
            backgroundColor: const Color(0xFF534AB7),
            tooltip: '카메라로 촬영',
            onPressed:
                _analyzing ? null : () => _addClothing(ImageSource.camera),
            child: const Icon(Icons.add_a_photo, color: Colors.white),
          ),
        ],
      ),
    );
  }

  // 옷 한 벌 카드
  Widget _buildClothCard(Map<String, String> cloth) {
    final imagePath = cloth['imagePath'] ?? '';
    // 경로가 있고 실제 파일이 존재할 때만 사진 표시, 아니면 아이콘 fallback
    final hasImage = imagePath.isNotEmpty && File(imagePath).existsSync();

    // 길게 누르기(onLongPress)와 우측 상단 휴지통 아이콘 둘 다로 삭제 가능
    return GestureDetector(
      onLongPress: () => _confirmDelete(cloth),
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
                // 사진 영역
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: hasImage
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(File(imagePath),
                                fit: BoxFit.cover),
                          )
                        : const Icon(Icons.checkroom,
                            size: 40, color: Colors.black26),
                  ),
                ),
                const SizedBox(height: 8),
                // 옷 종류(type)
                Text(cloth['type'] ?? '',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                // 카테고리 · 색상
                Text(
                  '${cloth['category'] ?? ''} · ${cloth['color'] ?? ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
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
                onTap: () => _confirmDelete(cloth),
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
