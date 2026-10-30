// ══════════════════════════════════════════════════════════════
// AiModels — Gemini 모델 ID를 한곳에서 관리
//
// 모델이 deprecated 되거나 교체될 때 이 파일만 수정하면 됨.
// (2026-10: gemini-2.5-* 계열이 신규 키로 접근 불가해지면서 전면 교체)
//
// 주의: 텍스트/비전 모델과 이미지 생성 모델은 별개임.
//   - gemini-3.8-flash       → 이미지를 '읽을' 수 있지만 '만들지'는 못함
//   - gemini-3.1-flash-image → 이미지 생성·편집 전용 (Nano Banana 2)
//
// TODO(Phase 3): Firebase Remote Config 도입 시 static const → getter 로 전환
// ══════════════════════════════════════════════════════════════

class AiModels {
  AiModels._();

  /// 의류 분석 등 텍스트·비전 추론용
  static const String vision = 'gemini-3.8-flash';

  /// 가상 피팅 이미지 생성 — 1순위 (빠름, Nano Banana 2)
  static const String imageGen = 'gemini-3.1-flash-image';

  /// 가상 피팅 이미지 생성 — 2순위 폴백 (고품질, Nano Banana Pro)
  static const String imageGenFallback = 'gemini-3-pro-image';

  /// 이미지 생성 모델 후보 (앞에서부터 시도 → 429/404면 다음 후보로)
  static const List<String> imageModelCandidates = [
    imageGen,
    imageGenFallback,
  ];
}
