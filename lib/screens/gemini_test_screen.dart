import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image_picker/image_picker.dart';

import '../secrets.dart';

class GeminiTestScreen extends StatefulWidget {
  const GeminiTestScreen({super.key});

  @override
  State<GeminiTestScreen> createState() => _GeminiTestScreenState();
}

class _GeminiTestScreenState extends State<GeminiTestScreen> {
  static const String _apiKey = Secrets.geminiApiKey;

  late final GenerativeModel _model;
  final ImagePicker _picker = ImagePicker();

  File? _pickedImage;
  String _response = '아직 호출 안 함';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: _apiKey,
    );
  }

  Future<void> _callGeminiText() async {
    setState(() {
      _loading = true;
      _response = '호출 중...';
    });

    try {
      final content = [
        Content.text('안녕하세요. MOIP-Z 앱 개발자 신민종입니다. '
            '한국어로 한 줄 인사 부탁드려요.')
      ];
      final result = await _model.generateContent(content);

      setState(() {
        _response = result.text ?? '응답이 비어있음';
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _response = '에러: $e';
        _loading = false;
      });
    }
  }

  Future<void> _pickImage() async {
    final XFile? picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );

    if (picked == null) return;

    setState(() {
      _pickedImage = File(picked.path);
      _response = '이미지 선택됨 — 분석 버튼을 눌러주세요';
    });
  }

  Future<void> _callGeminiWithImage() async {
    if (_pickedImage == null) {
      setState(() => _response = '먼저 이미지를 선택해주세요');
      return;
    }

    setState(() {
      _loading = true;
      _response = '이미지 분석 중...';
    });

    try {
      final imageBytes = await _pickedImage!.readAsBytes();

      // 옷 분류용 system prompt
// JSON 형식만 답하도록 강하게 지시
      const clothingPrompt = '''
당신은 의류 이미지 분석 전문가입니다.
주어진 이미지의 옷을 다음 JSON 형식으로만 답하세요.

{
  "category": "상의 또는 하의 또는 아우터 또는 신발 또는 기타 중 하나",
  "color": "주요 색상 (한국어, 예: 화이트, 네이비, 베이지)",
  "type": "구체적인 종류 (예: 옥스포드 셔츠, 슬림 청바지, 트렌치 코트)",
  "season": "봄 또는 여름 또는 가을 또는 겨울 또는 사계절 중 하나"
}

규칙:
- 설명이나 부연 없이 JSON 객체만 출력하세요.
- 마크다운 코드 블록(```)으로 감싸지 마세요.
- 이미지에 옷이 여러 벌이면 가장 두드러진 한 벌만 분석하세요.
- 의류가 아니면 category에 "기타"를 넣으세요.
''';

      final content = [
        Content.multi([
          TextPart(clothingPrompt),
          DataPart('image/jpeg', imageBytes),
        ])
      ];

      final result = await _model.generateContent(content);

      setState(() {
        _response = result.text ?? '응답이 비어있음';
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _response = '에러: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Gemini 호출 테스트'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('1. 텍스트만 보내기',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 6),
            ElevatedButton(
              onPressed: _loading ? null : _callGeminiText,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF534AB7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Gemini에게 인사하기'),
            ),

            const SizedBox(height: 24),

            const Text('2. 이미지 + 텍스트 보내기',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 6),

            Container(
              height: 200,
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFFF1EFE8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _pickedImage == null
                  ? const Center(
                child: Text('아직 이미지 없음',
                    style: TextStyle(color: Colors.black38)),
              )
                  : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(_pickedImage!, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 8),

            OutlinedButton.icon(
              onPressed: _loading ? null : _pickImage,
              icon: const Icon(Icons.photo_library, size: 18),
              label: const Text('갤러리에서 이미지 선택'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF534AB7),
                side: const BorderSide(color: Color(0xFF534AB7)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
            const SizedBox(height: 8),

            ElevatedButton.icon(
              onPressed: (_loading || _pickedImage == null)
                  ? null
                  : _callGeminiWithImage,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('이미지 분석 요청'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF534AB7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),

            const SizedBox(height: 24),

            const Text('응답:',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF1EFE8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _response,
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}