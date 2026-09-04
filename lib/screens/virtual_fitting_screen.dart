import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../services/gemini_service.dart';

// ══════════════════════════════════════════════════════════════
// VirtualFittingScreen — AI 가상 피팅 (Gemini 이미지 생성, Nano Banana)
//  흐름:
//   1) image_picker로 사용자 전신 사진 1장
//   2) 옷장(shared_preferences 'wardrobe_clothes')의 옷을 가로 스크롤로 다중 선택
//   3) '가상 피팅 시작' → gemini-2.5-flash-image REST 호출(inlineData base64)
//      → 응답의 inlineData(이미지)를 디코드해 결과 표시
//  게이팅: 사용자 사진 1장 + 옷 최소 1벌이면 활성화 (상·하의 조건 없음)
// ══════════════════════════════════════════════════════════════

// 이미지 생성 모델 후보 (앞에서부터 시도 → 429/404면 다음 후보로)
//  ★ 'gemini-2.5-flash-image' = 정식(GA). 'gemini-2.5-flash-image-preview' = 프리뷰.
//    (서버가 'gemini-2.5-flash-preview-image' 처럼 preview 별칭으로 해석해 quota 0이 나는
//     경우를 피하려고, 정식 ID를 1순위로 두고 후보를 순차 시도)
const List<String> _imageModelCandidates = [
  'gemini-2.5-flash-image',          // 1순위: 정식(GA)
  'gemini-2.5-flash-image-preview',  // 2순위: 프리뷰 (무료 티어가 이쪽만 열린 경우 대비)
];

// 모델 ID → generateContent REST 엔드포인트
String _endpointFor(String model) =>
    'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';

// 합성 프롬프트 — 얼굴/정체성 보존을 강하게 지시 (한국어 + 영문 병기)
const String _fittingPrompt =
    '첫 번째 이미지 속 인물의 얼굴, 머리스타일, 피부톤, 체형을 절대 바꾸지 말고 '
    '그대로 100% 유지하세요. 오직 의류만 교체/착용시키세요. '
    '얼굴을 새로 생성하거나 다른 사람으로 바꾸면 안 됩니다. '
    '나머지 이미지들은 의류입니다. 이 인물이 해당 의류를 자연스럽게 착용한 '
    '전신 모습을 사실적으로 합성해 주세요.\n'
    'Preserve the exact face, identity, hairstyle, skin tone, and body of the '
    'person in the first image. Do NOT generate a new face or replace the person. '
    'Only change the clothing.';

class VirtualFittingScreen extends StatefulWidget {
  const VirtualFittingScreen({super.key});

  @override
  State<VirtualFittingScreen> createState() => _VirtualFittingScreenState();
}

class _VirtualFittingScreenState extends State<VirtualFittingScreen> {
  static const Color _brand = Color(0xFF534AB7);

  final ImagePicker _picker = ImagePicker();

  // ── 사용자 사진 ──────────────────────────────
  File? _userPhoto;

  // ── 옷장 데이터 ──────────────────────────────
  // 항목 구조: {category, color, type, season, imagePath}
  List<Map<String, String>> _clothes = [];
  bool _clothesLoading = true;
  final Set<int> _selected = {}; // 다중 선택된 옷 인덱스

  // ── 피팅 상태 ────────────────────────────────
  bool _fitting = false;     // 합성 중
  bool _error = false;       // 합성 실패
  String? _errorDetail;      // 실패 원인 요약(상태코드/메시지 첫 줄) — 디버깅용
  Uint8List? _resultImage;   // 합성 결과 이미지

  @override
  void initState() {
    super.initState();
    _loadClothes(); // 옷장 옷 불러오기
  }

  // ── 옷장 옷 불러오기 ─────────────────────────
  Future<void> _loadClothes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('wardrobe_clothes');
    List<Map<String, String>> loaded = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        loaded = decoded.map((e) => Map<String, String>.from(e as Map)).toList();
      } catch (_) {/* 손상된 JSON이면 빈 목록 */}
    }
    if (!mounted) return;
    setState(() {
      _clothes = loaded;
      _clothesLoading = false;
    });
  }

  // 피팅 시작 가능 여부: 사진 1장 + 옷 최소 1벌
  bool get _canFit => _userPhoto != null && _selected.isNotEmpty;

  // ── 사용자 사진 선택 (갤러리/카메라) ─────────
  Future<void> _pickUserPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library, color: _brand),
              title: const Text('앨범에서 선택'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: _brand),
              title: const Text('카메라로 촬영'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final XFile? picked = await _picker.pickImage(
      source: source,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 90,
    );
    if (picked == null) return;

    setState(() {
      _userPhoto = File(picked.path);
      _resultImage = null; // 새 사진이면 이전 결과 무효화
      _error = false;
    });
  }

  // ── 옷 선택 토글 ─────────────────────────────
  void _toggleCloth(int index) {
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        _selected.add(index);
      }
      // 선택이 바뀌면 이전 결과는 무효화
      _resultImage = null;
      _error = false;
    });
  }

  // ════════════════════════════════════════════════════════════
  // AI 합성 — gemini-2.5-flash-image REST 직접 호출
  // ════════════════════════════════════════════════════════════
  Future<void> _startFitting() async {
    if (!_canFit) return;
    setState(() {
      _fitting = true;
      _error = false;
      _errorDetail = null;
      _resultImage = null;
    });

    try {
      // 1) parts 구성: 텍스트 → 사용자 사진 → 선택한 옷 사진들
      //    ★ base64Encode는 'data:image/...;base64,' 접두어 없는 순수 base64를 반환
      final parts = <Map<String, dynamic>>[
        {'text': _fittingPrompt},
      ];

      final userBytes = await _userPhoto!.readAsBytes();
      parts.add({
        'inlineData': {
          'mimeType': 'image/jpeg',
          'data': base64Encode(userBytes),
        }
      });

      // 선택한 옷 중 실제 이미지 파일이 있는 것만 첨부
      var attachedClothes = 0;
      for (final i in _selected) {
        final path = _clothes[i]['imagePath'] ?? '';
        if (path.isEmpty) continue;
        final f = File(path);
        if (!f.existsSync()) continue;
        final b = await f.readAsBytes();
        parts.add({
          'inlineData': {
            'mimeType': 'image/jpeg',
            'data': base64Encode(b),
          }
        });
        attachedClothes++;
      }

      // [DEBUG] 첨부 이미지 점검 — 옷 이미지가 0장이면 합성이 무의미
      // ignore: avoid_print
      print('[fitting] 선택 ${_selected.length}벌 중 실제 이미지 첨부 $attachedClothes장 '
          '(parts: 텍스트1 + 사람1 + 옷$attachedClothes)');
      if (attachedClothes == 0) {
        throw Exception('선택한 옷에 사용할 이미지가 없습니다 '
            '(옷장 항목의 imagePath 파일이 없음). 사진이 있는 옷을 선택하세요.');
      }

      // 2) 요청 본문 (이미지 출력 모달리티 명시) — 모든 후보에 동일 본문 사용
      final body = jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'responseModalities': ['TEXT', 'IMAGE'],
        },
      });

      // 3) 모델 후보를 순차 시도 (429/404 등이면 다음 후보로)
      Uint8List? image;
      String? lastError;

      for (final model in _imageModelCandidates) {
        final endpoint = _endpointFor(model);
        final url = Uri.parse('$endpoint?key=${GeminiService.apiKey}');

        // [DEBUG] ★ 최종 요청 URL 전체 출력 — 실제로 어떤 모델로 가는지 확인
        // ignore: avoid_print
        print('[fitting] === 시도 모델: $model ===');
        // ignore: avoid_print
        print('[fitting] 최종 요청 URL=$url');

        http.Response res;
        try {
          res = await http
              .post(url,
                  headers: {'Content-Type': 'application/json'}, body: body)
              .timeout(const Duration(seconds: 60));
        } catch (e) {
          // 네트워크/타임아웃 → 다음 후보
          lastError = '네트워크 오류 ($model): $e';
          // ignore: avoid_print
          print('[fitting] $lastError');
          continue;
        }

        // [DEBUG] 응답 상태 + 본문 전문
        // ignore: avoid_print
        print('[fitting] [$model] status=${res.statusCode}');
        // ignore: avoid_print
        print('[fitting] [$model] body=${res.body}');

        // 401/403(권한)/404(모델없음)/429(쿼터) → 다음 후보로
        if (res.statusCode != 200) {
          lastError = 'HTTP ${res.statusCode} ($model): ${_firstLine(res.body)}';
          continue;
        }

        // 파싱
        final data = jsonDecode(res.body) as Map<String, dynamic>;

        final promptFeedback = data['promptFeedback'];
        if (promptFeedback != null) {
          // ignore: avoid_print
          print('[fitting] [$model] promptFeedback=$promptFeedback');
        }

        final candidates = data['candidates'] as List<dynamic>?;
        if (candidates == null || candidates.isEmpty) {
          lastError = 'candidates 없음 ($model, 안전필터 차단 가능): '
              '${promptFeedback ?? _firstLine(res.body)}';
          continue;
        }

        final first = candidates.first as Map<String, dynamic>;
        final finishReason = first['finishReason'];
        final content = first['content'] as Map<String, dynamic>?;
        final respParts = content?['parts'] as List<dynamic>?;

        // ignore: avoid_print
        print('[fitting] [$model] finishReason=$finishReason, '
            'parts=${respParts?.length ?? 0}');

        if (respParts != null) {
          for (final p in respParts) {
            if (p is! Map) continue;
            // 이미지 모델은 camelCase 'inlineData' (snake_case도 방어적으로 처리)
            final inline = p['inlineData'] ?? p['inline_data'];
            if (inline is Map && inline['data'] != null) {
              image = base64Decode(inline['data'].toString());
              break;
            }
          }
        }

        if (image != null) {
          // ignore: avoid_print
          print('[fitting] ★ 성공 모델=$model');
          break; // 성공 → 후보 루프 종료
        }

        // 200인데 이미지 없음 → 다음 후보로
        lastError = '이미지 파트 없음 ($model, finishReason=$finishReason, '
            'parts=${respParts?.length ?? 0})';
      }

      if (image == null) {
        throw Exception(lastError ?? '모든 이미지 모델 후보가 실패했습니다.');
      }

      if (!mounted) return;
      setState(() {
        _resultImage = image;
        _fitting = false;
      });
    } catch (e, st) {
      // ★ 디버깅: 에러를 삼키지 말고 전체 + 스택을 콘솔에 남김
      // ignore: avoid_print
      print('[fitting] ERROR: $e');
      // ignore: avoid_print
      print('[fitting] STACK: $st');

      if (!mounted) return;
      setState(() {
        _fitting = false;
        _error = true;
        _errorDetail = e.toString();
      });
    }
  }

  // 본문에서 첫 줄(또는 앞부분)만 잘라 화면/로그 요약용으로
  String _firstLine(String s) {
    final trimmed = s.trim().replaceAll('\n', ' ');
    return trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed;
  }

  // ── 결과 이미지 저장 → 파일 + fitting_history 기록 ──
  //   fitting_history 항목 구조: { date(ISO), imagePath, clothNames(list) }
  Future<void> _saveResult() async {
    if (_resultImage == null) return;
    try {
      // 1) 결과 이미지를 documents 폴더에 파일로 저장
      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}${Platform.pathSeparator}fitting_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(_resultImage!);

      // 2) 저장 당시 선택했던 옷 이름들 (wardrobe 항목의 'type')
      final clothNames = _selected
          .map((i) => _clothes[i]['type'] ?? '')
          .where((s) => s.isNotEmpty)
          .toList();

      // 3) shared_preferences 'fitting_history'에 추가
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('fitting_history');
      final List<dynamic> history = (raw != null && raw.isNotEmpty)
          ? (jsonDecode(raw) as List<dynamic>)
          : <dynamic>[];
      history.add({
        'date': DateTime.now().toIso8601String(),
        'imagePath': path,
        'clothNames': clothNames,
      });
      await prefs.setString('fitting_history', jsonEncode(history));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('피팅 결과를 저장했어요 (옷장 → 피팅 사진 모음에서 확인)'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('저장에 실패했어요'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  // 다시 입어보기 — 결과만 비우고 사진/선택은 유지
  void _resetResult() {
    setState(() {
      _resultImage = null;
      _error = false;
      _errorDetail = null;
    });
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
          '가상 피팅',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
            fontSize: 17,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, color: Colors.black54),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('사진 추가 → 옷 선택(여러 벌 가능) → 피팅 시작'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ── 1. 미리보기/결과 영역 ────────────────
          Expanded(child: _buildPreviewArea()),

          // ── 2. 옷 선택 헤더 ──────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '입어볼 옷을 선택하세요',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(
                  '선택 ${_selected.length} / ${_clothes.length}벌',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // ── 3. 옷 선택 가로 스크롤 ───────────────
          SizedBox(height: 90, child: _buildClothList()),

          const SizedBox(height: 16),

          // ── 4. 하단 액션 버튼 ────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: _buildBottomAction(),
          ),
        ],
      ),
    );
  }

  // ── 미리보기/결과 영역 ───────────────────────
  Widget _buildPreviewArea() {
    Widget child;

    if (_fitting) {
      // 합성 중
      child = const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: _brand),
          SizedBox(height: 16),
          Text('AI가 피팅 중이에요...',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black54)),
          SizedBox(height: 4),
          Text('수 초~십수 초 걸릴 수 있어요',
              style: TextStyle(fontSize: 11, color: Colors.black38)),
        ],
      );
    } else if (_error) {
      // 실패 → 재시도
      child = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.black26),
          const SizedBox(height: 12),
          const Text('피팅에 실패했어요. 다시 시도',
              style: TextStyle(fontSize: 14, color: Colors.black54)),
          // ★ 디버깅용 에러 요약 (원인 바로 확인) — 운영 배포 전 제거
          if (_errorDetail != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _errorDetail!,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11, color: Colors.redAccent, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _startFitting,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                color: _brand,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, color: Colors.white, size: 16),
                  SizedBox(width: 6),
                  Text('재시도',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      );
    } else if (_resultImage != null) {
      // 합성 결과
      child = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.memory(_resultImage!, fit: BoxFit.contain),
      );
    } else if (_userPhoto != null) {
      // 선택한 사용자 사진 미리보기 + 변경 버튼
      child = Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(_userPhoto!, fit: BoxFit.contain),
          ),
          Positioned(
            right: 10,
            bottom: 10,
            child: GestureDetector(
              onTap: _pickUserPhoto,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('사진 변경',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          ),
        ],
      );
    } else {
      // 사진 없음 → 추가 placeholder
      child = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.camera_alt_outlined, size: 56, color: Colors.black26),
          const SizedBox(height: 12),
          const Text('신민종님의 전신 사진을 추가해주세요',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black54)),
          const SizedBox(height: 4),
          // ★ 정직한 프라이버시 문구로 정정 (온디바이스 아님)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'AI 합성을 위해 사진이 처리되며, 서버에 저장되지 않습니다',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black38),
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _pickUserPhoto,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _brand),
              ),
              child: const Text('사진 추가',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _brand)),
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EFE8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black12, width: 1),
      ),
      child: Center(child: child),
    );
  }

  // ── 옷 가로 스크롤 ───────────────────────────
  Widget _buildClothList() {
    if (_clothesLoading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: _brand),
        ),
      );
    }
    if (_clothes.isEmpty) {
      return const Center(
        child: Text('옷장에 옷이 없어요. 먼저 옷장에 옷을 추가해주세요',
            style: TextStyle(fontSize: 12, color: Colors.black38)),
      );
    }

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _clothes.length,
      itemBuilder: (context, index) {
        final cloth = _clothes[index];
        final isSelected = _selected.contains(index);
        final imagePath = cloth['imagePath'] ?? '';
        final hasImage = imagePath.isNotEmpty && File(imagePath).existsSync();

        return GestureDetector(
          onTap: () => _toggleCloth(index),
          child: Container(
            width: 70,
            margin: const EdgeInsets.only(right: 10),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFFF1EFE8),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? _brand : Colors.transparent,
                width: 2,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 썸네일 (실제 imagePath, 없으면 아이콘)
                if (hasImage)
                  Image.file(File(imagePath), fit: BoxFit.cover)
                else
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.checkroom,
                          color: Colors.black38, size: 26),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          cloth['type'] ?? '',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                // 선택 표시 체크
                if (isSelected)
                  Positioned(
                    top: 3,
                    right: 3,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: _brand,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: const Icon(Icons.check,
                          color: Colors.white, size: 12),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 하단 액션: 결과 유무에 따라 버튼 구성 ────
  Widget _buildBottomAction() {
    // 결과가 있으면: 안내 문구 + (다시 입어보기 / 저장)
    if (_resultImage != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '얼굴이 어색하거나 잘 안 맞으면 \'다시 입어보기\'로 재생성해보세요',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.black45),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _resetResult,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _brand),
                    ),
                    child: const Center(
                      child: Text('다시 입어보기',
                          style: TextStyle(
                              color: _brand,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: _saveResult,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    decoration: BoxDecoration(
                      color: _brand,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Text('저장',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    // 기본: 가상 피팅 시작 (게이팅)
    final enabled = _canFit && !_fitting;
    return SizedBox(
      width: double.infinity,
      child: GestureDetector(
        onTap: enabled ? _startFitting : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: enabled ? _brand : const Color(0xFFB8B3E0),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_awesome, color: Colors.white, size: 18),
              SizedBox(width: 6),
              Text('가상 피팅 시작',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
