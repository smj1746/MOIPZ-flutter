import 'dart:convert';
import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';

import '../secrets.dart';

// ══════════════════════════════════════════════════════════════
// GeminiService — Gemini API 호출을 담당하는 공통 서비스
// 모든 화면이 이 서비스 하나를 통해 AI를 호출함
// (API 키·모델·프롬프트·JSON 정리를 여기 한 곳에서 관리)
// ══════════════════════════════════════════════════════════════

class GeminiService {
  // ── 싱글톤 패턴 ──────────────────────────────
  // 앱 전체에서 GeminiService 인스턴스를 딱 하나만 만들어 공유함
  // 호출할 때: GeminiService.instance.analyzeClothing(...)
  GeminiService._();                                  // private 생성자 (외부에서 new 불가)
  static final GeminiService instance = GeminiService._();  // 유일한 인스턴스

  // API 키는 lib/secrets.dart (gitignore 처리됨)에서 관리
  static const String _apiKey = Secrets.geminiApiKey;

  // 다른 화면에서 REST 직접 호출 시 같은 키를 재사용할 수 있게 공개 (예: 가상 피팅)
  static String get apiKey => _apiKey;

  // Gemini 모델 — 앱 시작 후 처음 호출될 때 한 번만 생성됨
  final GenerativeModel _model =
  GenerativeModel(model: 'gemini-2.5-flash', apiKey: _apiKey);

  // ── 1) 텍스트만 보내기 (인사 테스트용) ──────────
  Future<String> sendText(String prompt) async {
    final result = await _model.generateContent([Content.text(prompt)]);
    return result.text ?? '응답이 비어있음';
  }

  // ── 2) 이미지 설명 (일반 이미지 테스트용) ────────
  Future<String> describeImage(Uint8List imageBytes) async {
    final content = [
      Content.multi([
        TextPart('이 이미지에 무엇이 보이는지 한국어로 두 문장 안에 설명해주세요.'),
        DataPart('image/jpeg', imageBytes),
      ])
    ];
    final result = await _model.generateContent(content);
    return result.text ?? '응답이 비어있음';
  }

  // ── 3) 옷 이미지 분석 → Map 반환 (핵심 기능) ─────
  // 성공 시 {category, color, type, season} 형태의 Map 반환
  // 실패 시 예외 발생 (호출하는 쪽에서 try-catch)
  Future<Map<String, dynamic>> analyzeClothing(Uint8List imageBytes) async {
    const clothingPrompt = '''
당신은 의류 이미지 분석 전문가입니다.
주어진 이미지의 옷을 다음 JSON 형식으로만 답하세요.

{
  "category": "상의 또는 하의 또는 아우터 또는 신발 또는 기타 중 하나",
  "color": "주요 색상 (한국어)",
  "type": "구체적인 종류 (예: 옥스포드 셔츠, 슬림 청바지)",
  "season": "봄 또는 여름 또는 가을 또는 겨울 또는 사계절 중 하나"
}

규칙:
- 설명 없이 JSON 객체만 출력하세요.
- 마크다운 코드 블록으로 감싸지 마세요.
- 의류가 아니면 category에 "기타"를 넣으세요.
''';

    final content = [
      Content.multi([
        TextPart(clothingPrompt),
        DataPart('image/jpeg', imageBytes),
      ])
    ];

    final result = await _model.generateContent(content);
    final cleaned = _cleanJsonResponse(result.text ?? '');
    return jsonDecode(cleaned) as Map<String, dynamic>;
  }

  // ── 4) 코디 추천 → Map 반환 (AI 코디 화면) ───────
  // 입력: 상황 / 날씨(기온·상태) / 사용자 프로필 / 보유 옷 목록
  // 성공 시 {jacket, top, bottom, shoes, accessory} 형태의 Map 반환
  //   각 항목은 {name, reason, owned(boolean), wardrobeIndex(int)}
  //   ※ wardrobe_clothes 항목에는 고유 id가 없으므로 '목록 인덱스'를 식별자로 사용.
  //     보유 옷에서 고른 항목은 그 옷의 index를 wardrobeIndex로 되돌려 받아
  //     화면에서 imagePath를 찾아 표시함. 새 제안/매칭없음은 -1.
  // 실패 시 예외 발생 (호출하는 쪽에서 try-catch → 재시도 안내)
  Future<Map<String, dynamic>> recommendCoordi({
    required String situation,          // 출근/데이트/운동/캐주얼
    required int temp,                  // 기온(℃)
    required String condition,          // 한글 날씨 상태
    required Map<String, dynamic> profile,   // user_profile
    required List<dynamic> wardrobe,    // wardrobe_clothes (각 항목 category/color/type/season/imagePath)
    bool different = false,             // true면 다양성 강화 지시 추가
    List<String> previousItems = const [], // 직전 추천 아이템 이름들 (different일 때 제외/변주 근거)
  }) async {
    const encoder = JsonEncoder.withIndent('  ');
    final profileJson = encoder.convert(profile);

    // ★ 옷장 각 항목에 'index'를 명시적으로 부여해서 프롬프트에 전달.
    //   (imagePath는 모델에 불필요하므로 제외 — 토큰 절약 + 노이즈 감소)
    final indexedWardrobe = <Map<String, dynamic>>[];
    for (var i = 0; i < wardrobe.length; i++) {
      final item = wardrobe[i];
      if (item is! Map) continue;
      indexedWardrobe.add({
        'index': i,
        'category': item['category'],
        'color': item['color'],
        'type': item['type'],
        'season': item['season'],
      });
    }
    final wardrobeJson = encoder.convert(indexedWardrobe);

    // 다양성 강화 블록 (다른 코디 추천받기에서 different=true로 호출)
    final diversityBlock = different
        ? '''

[다양성 강화]
- 아래는 직전에 추천했던 아이템들입니다. 가능하면 제외하거나 다른 조합으로 바꿔주세요:
  ${previousItems.isEmpty ? '(직전 목록 없음)' : previousItems.join(', ')}
- 보유 옷이 적어 완전히 다른 조합이 어렵다면, 같은 옷이라도 다른 상황 해석이나
  다른 매칭(예: 같은 셔츠 + 다른 하의)으로 변주하세요.
- 단, 상황·날씨·프로필에 맞지 않는 아이템을 억지로 넣지는 마세요. 추천 품질을 우선합니다.'''
        : '';

    final prompt = '''
당신은 전문 패션 코디네이터입니다.

[상황] $situation
[날씨] 기온 $temp°C, 상태 $condition

[사용자 프로필]
$profileJson

[보유 옷 목록] (각 항목의 index가 고유 식별자입니다)
$wardrobeJson

요청:
- 위 보유 옷 목록에서 우선적으로 골라, 주어진 상황·날씨·사용자 프로필
  (키/체형/선호스타일/피부톤)에 맞는 코디를
  자켓 → 상의 → 하의 → 신발 → 악세서리 순서로 추천하세요.
- 보유 옷에서 고른 항목은 owned=true 로 표시하고, 그 옷의 index 값을 wardrobeIndex 에 넣으세요.
- 보유 옷에 적합한 것이 없는 항목만 새 아이템을 제안하고, 그 항목은 owned=false,
  wardrobeIndex 는 -1 로 두세요.
- 해당 상황·날씨에 불필요한 항목(예: 운동에 자켓 불필요, 더운 날씨에 자켓 불필요)은
  name 을 빈 문자열("")로 두세요.$diversityBlock

응답 규칙:
- 마크다운이나 코드블록(```)으로 감싸지 말고, 순수 JSON 객체만 출력하세요.
- reason 은 한국어 한 문장으로 간결하게 쓰세요.
- wardrobeIndex 는 반드시 정수(보유 옷의 index 또는 -1)로 쓰세요.
- 형식:
{
  "jacket":    {"name": "", "reason": "", "owned": true, "wardrobeIndex": -1},
  "top":       {"name": "", "reason": "", "owned": true, "wardrobeIndex": -1},
  "bottom":    {"name": "", "reason": "", "owned": true, "wardrobeIndex": -1},
  "shoes":     {"name": "", "reason": "", "owned": true, "wardrobeIndex": -1},
  "accessory": {"name": "", "reason": "", "owned": true, "wardrobeIndex": -1}
}
''';

    // 다양성 확보를 위해 temperature를 약간 높임 (different일 때 더 높게)
    final result = await _model.generateContent(
      [Content.text(prompt)],
      generationConfig: GenerationConfig(
        temperature: different ? 1.3 : 0.9,
      ),
    );
    // ★ 기존 _cleanJsonResponse로 정제 후 디코딩 (실패 시 예외 → 호출부에서 처리)
    final cleaned = _cleanJsonResponse(result.text ?? '');
    return jsonDecode(cleaned) as Map<String, dynamic>;
  }

  // ── 응답에서 ```json 등을 제거하고 순수 JSON만 추출 ──
  // private 메서드 (_로 시작) — 이 파일 안에서만 사용
  String _cleanJsonResponse(String raw) {
    String cleaned = raw.trim();
    if (cleaned.startsWith('```json')) {
      cleaned = cleaned.substring(7).trim();
    } else if (cleaned.startsWith('```')) {
      cleaned = cleaned.substring(3).trim();
    }
    if (cleaned.endsWith('```')) {
      cleaned = cleaned.substring(0, cleaned.length - 3).trim();
    }
    final firstBrace = cleaned.indexOf('{');
    final lastBrace = cleaned.lastIndexOf('}');
    if (firstBrace != -1 && lastBrace != -1) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }
    return cleaned;
  }
}

