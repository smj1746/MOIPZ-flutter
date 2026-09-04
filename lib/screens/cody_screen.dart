import 'secrets.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/gemini_service.dart';
import 'home_screen.dart' show owmApiKey; // OWM 키 재사용 (단일 출처)

// ══════════════════════════════════════════════════════════════
// CodyScreen — AI 코디 추천 화면 (실제 추천 연동)
//  입력: 상황(출근/데이트/운동/캐주얼) + 날씨(기온/상태) + 프로필 + 보유 옷
//   → GeminiService.recommendCoordi 호출
//   → {jacket, top, bottom, shoes, accessory} JSON 파싱
//   → 5개 카드(자켓/상의/하의/신발/악세서리) 표시 (name 빈 항목은 생략)
//
//  ★ 날씨는 홈에서 넘겨준 값을 재사용. 없으면 같은 방식(OWM→Open-Meteo→더미)으로 재호출
// ══════════════════════════════════════════════════════════════

// 코디 한 항목 (카드 1개에 대응)
class _CoordiItem {
  final String label;       // 자켓 / 상의 / 하의 / 신발 / 악세서리
  final String name;        // 옷 이름
  final String reason;      // 추천 이유(한 줄)
  final bool owned;         // true=보유, false=추천 구매
  final String? imagePath;  // 매칭된 옷장 이미지 경로 (없으면 null → 아이콘 fallback)

  const _CoordiItem({
    required this.label,
    required this.name,
    required this.reason,
    required this.owned,
    this.imagePath,
  });
}

class CodyScreen extends StatefulWidget {
  // 홈 화면에서 이미 불러온 날씨 값을 재사용하기 위한 선택 파라미터
  final int? initialTemp;
  final String? initialCondition;

  const CodyScreen({
    super.key,
    this.initialTemp,
    this.initialCondition,
  });

  @override
  State<CodyScreen> createState() => CodyScreenState();
}

class CodyScreenState extends State<CodyScreen> {
  // ── 상황 선택 ────────────────────────────────
  int _selectedSituation = 0;
  final List<String> _situations = ['출근', '데이트', '운동', '캐주얼'];

  // 추천 시도 횟수 (헤더에 #N 표시 — 갱신 확인용)
  int _recommendCount = 1;

  // ── 날씨 ─────────────────────────────────────
  int? _temp;
  String? _condition;

  // ── 추천 상태 ────────────────────────────────
  bool _loading = true;          // 추천 호출 중
  bool _error = false;           // 추천/파싱 실패
  List<_CoordiItem> _items = [];

  // 직전 추천 아이템 이름들 — '다른 코디 추천받기'에서 다양성 강화용으로 전달
  List<String> _lastNames = [];

  // gemini_service의 슬롯 키 ↔ 화면 라벨 (추천 순서 그대로)
  static const List<(String, String)> _slots = [
    ('jacket', '자켓'),
    ('top', '상의'),
    ('bottom', '하의'),
    ('shoes', '신발'),
    ('accessory', '악세서리'),
  ];

  @override
  void initState() {
    super.initState();
    // 홈에서 넘겨준 날씨가 있으면 우선 사용
    _temp = widget.initialTemp;
    _condition = widget.initialCondition;
    _initAndRecommend();
  }

  // 날씨 확보 후 첫 추천 호출
  Future<void> _initAndRecommend() async {
    // 날씨가 안 넘어왔으면 같은 방식으로 직접 호출
    if (_temp == null || _condition == null) {
      final (t, c) = await _fetchWeatherFallback();
      if (!mounted) return;
      setState(() {
        _temp = t;
        _condition = c;
      });
    }
    await _fetchRecommendation();
  }

  // ════════════════════════════════════════════════════════════
  // 추천 호출 — 프로필/옷장을 prefs에서 읽어 GeminiService로 전달
  // ════════════════════════════════════════════════════════════
  Future<void> _fetchRecommendation({bool different = false}) async {
    setState(() {
      _loading = true;
      _error = false;
    });

    // 프로필 / 옷장 읽기 (★ 저장된 키 구조 그대로)
    final prefs = await SharedPreferences.getInstance();

    Map<String, dynamic> profile = {};
    final profileRaw = prefs.getString('user_profile');
    if (profileRaw != null && profileRaw.isNotEmpty) {
      try {
        profile = jsonDecode(profileRaw) as Map<String, dynamic>;
      } catch (_) {/* 손상된 JSON이면 빈 프로필로 진행 */}
    }

    List<dynamic> wardrobe = [];
    final wardrobeRaw = prefs.getString('wardrobe_clothes');
    if (wardrobeRaw != null && wardrobeRaw.isNotEmpty) {
      try {
        wardrobe = jsonDecode(wardrobeRaw) as List<dynamic>;
      } catch (_) {/* 손상된 JSON이면 빈 옷장으로 진행 */}
    }

    try {
      final json = await GeminiService.instance.recommendCoordi(
        situation: _situations[_selectedSituation],
        temp: _temp ?? 18,
        condition: _condition ?? '맑음',
        profile: profile,
        wardrobe: wardrobe,
        different: different,
        // 재호출 시 직전 추천 이름들을 넘겨 '제외/변주' 지시 근거로 사용
        previousItems: different ? _lastNames : const [],
      );

      // 옷장(wardrobe)을 함께 넘겨 owned 항목의 imagePath를 인덱스로 매칭
      final parsed = _parseItems(json, wardrobe);
      if (!mounted) return;
      setState(() {
        _items = parsed;
        _lastNames = parsed.map((e) => e.name).toList(); // 다음 재호출용으로 기록
        _loading = false;
        _error = parsed.isEmpty; // 유효 항목이 0개면 실패로 간주
      });
    } catch (_) {
      // 네트워크/파싱 실패 → 재시도 안내
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  // JSON → 카드 목록 (name 빈 항목은 제외, 슬롯 순서 유지)
  //  owned=true 항목은 wardrobeIndex로 옷장 옷을 찾아 imagePath를 매칭
  List<_CoordiItem> _parseItems(Map<String, dynamic> json, List<dynamic> wardrobe) {
    final list = <_CoordiItem>[];
    for (final slot in _slots) {
      final raw = json[slot.$1];
      if (raw is! Map) continue;
      final name = (raw['name'] ?? '').toString().trim();
      if (name.isEmpty) continue; // 빈 항목 카드 생략
      final reason = (raw['reason'] ?? '').toString().trim();
      final ownedRaw = raw['owned'];
      final owned =
          ownedRaw == true || ownedRaw?.toString().toLowerCase() == 'true';

      // 보유 옷이면 wardrobeIndex(또는 wardrobeId)로 옷장 이미지 경로 찾기
      String? imagePath;
      if (owned) {
        final idx = _asIndex(raw['wardrobeIndex'] ?? raw['wardrobeId']);
        if (idx != null && idx >= 0 && idx < wardrobe.length) {
          final w = wardrobe[idx];
          if (w is Map) {
            final p = (w['imagePath'] ?? '').toString();
            // 실제 파일이 있을 때만 채택 (없으면 null → 아이콘 fallback)
            if (p.isNotEmpty && File(p).existsSync()) {
              imagePath = p;
            }
          }
        }
      }

      list.add(_CoordiItem(
        label: slot.$2,
        name: name,
        reason: reason,
        owned: owned,
        imagePath: imagePath,
      ));
    }
    return list;
  }

  // 다양한 타입(int/num/String)으로 올 수 있는 인덱스를 안전하게 int로
  int? _asIndex(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  // ── 날씨 fallback (홈에서 안 넘어온 경우) ────────
  //   홈과 동일 방식: 위치 → OWM → Open-Meteo → 더미
  Future<(int, String)> _fetchWeatherFallback() async {
    double lat = 36.99, lon = 127.11; // 평택 fallback
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (enabled) {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm != LocationPermission.denied &&
            perm != LocationPermission.deniedForever) {
          final p = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.low),
          );
          lat = p.latitude;
          lon = p.longitude;
        }
      }
    } catch (_) {/* 위치 실패 → 평택 좌표 유지 */}

    // OWM 우선
    try {
      final res = await http
          .get(Uri.parse(
            'https://api.openweathermap.org/data/2.5/weather'
            '?lat=$lat&lon=$lon&appid=$owmApiKey&units=metric&lang=kr',
          ))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        final t = (d['main']?['temp'] as num?)?.round();
        final wl = d['weather'] as List<dynamic>?;
        final desc = (wl != null && wl.isNotEmpty)
            ? wl.first['description']?.toString()
            : null;
        if (t != null) return (t, desc ?? '날씨 정보');
      }
    } catch (_) {/* → Open-Meteo */}

    // Open-Meteo fallback (키 불필요)
    try {
      final res = await http
          .get(Uri.parse(
            'https://api.open-meteo.com/v1/forecast'
            '?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code',
          ))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body) as Map<String, dynamic>;
        final c = d['current'] as Map<String, dynamic>?;
        final t = (c?['temperature_2m'] as num?)?.round();
        final code = (c?['weather_code'] as num?)?.toInt();
        if (t != null) return (t, _wmoToKr(code ?? 0));
      }
    } catch (_) {/* → 더미 */}

    return (18, '맑음'); // 최종 더미
  }

  String _wmoToKr(int code) {
    if (code == 0) return '맑음';
    if (code == 1) return '대체로 맑음';
    if (code == 2) return '구름 조금';
    if (code == 3) return '흐림';
    if (code == 45 || code == 48) return '안개';
    if (code >= 51 && code <= 57) return '이슬비';
    if (code >= 61 && code <= 67) return '비';
    if (code >= 71 && code <= 77) return '눈';
    if (code >= 80 && code <= 82) return '소나기';
    if (code >= 85 && code <= 86) return '눈 소나기';
    if (code >= 95) return '뇌우';
    return '날씨 정보';
  }

  // 기온 기반 한 줄 코멘트 (날씨 카드 보조 문구)
  String _weatherNote(int t) {
    if (t >= 28) return '더운 날씨 — 가볍고 시원하게';
    if (t >= 23) return '따뜻해요 — 얇은 옷 추천';
    if (t >= 17) return '활동하기 좋은 날씨';
    if (t >= 12) return '선선해요 — 가벼운 겉옷 추천';
    if (t >= 5) return '쌀쌀해요 — 따뜻하게';
    return '추운 날씨 — 두껍게 입어요';
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
          'AI 코디 추천',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
            fontSize: 17,
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. 날씨 정보 카드 ─────────────────────
            _buildWeatherCard(),

            const SizedBox(height: 20),

            // ── 2. 상황 선택 ─────────────────────────
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '어떤 상황인가요?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: List.generate(_situations.length, (index) {
                  final isSelected = index == _selectedSituation;
                  return Expanded(
                    child: GestureDetector(
                      onTap: _loading
                          ? null
                          : () {
                              // 상황을 바꾸면 곧바로 새 추천 호출
                              setState(() {
                                _selectedSituation = index;
                                _recommendCount++;
                              });
                              _fetchRecommendation();
                            },
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF534AB7)
                              : const Color(0xFFF1EFE8),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            _situations[index],
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color:
                                  isSelected ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),

            const SizedBox(height: 24),

            // ── 3. 추천 결과 헤더 ────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'AI가 골랐어요',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '추천 #$_recommendCount',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF534AB7),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── 4. 추천 결과 (로딩 / 에러 / 카드) ────
            _buildResultArea(),

            const SizedBox(height: 16),

            // ── 5. 다른 코디 추천받기 ────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: GestureDetector(
                  onTap: _loading
                      ? null
                      : () {
                          setState(() => _recommendCount++);
                          // 같은 입력 + '이전과 다른 조합으로' 지시
                          _fetchRecommendation(different: true);
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: _loading
                          ? const Color(0xFFB8B3E0)
                          : const Color(0xFF534AB7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.refresh, color: Colors.white, size: 18),
                        SizedBox(width: 6),
                        Text(
                          '다른 코디 추천받기',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ── 날씨 카드 ────────────────────────────────
  Widget _buildWeatherCard() {
    final ready = _temp != null && _condition != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F1FB),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.wb_sunny, color: Color(0xFF185FA5), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: ready
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_temp° · $_condition',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0C447C),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _weatherNote(_temp!),
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF185FA5)),
                      ),
                    ],
                  )
                : const Text(
                    '날씨 불러오는 중...',
                    style: TextStyle(fontSize: 13, color: Color(0xFF185FA5)),
                  ),
          ),
        ],
      ),
    );
  }

  // ── 추천 결과 영역 ───────────────────────────
  Widget _buildResultArea() {
    // 로딩 중 스피너
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Column(
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.6,
                  color: Color(0xFF534AB7),
                ),
              ),
              SizedBox(height: 12),
              Text('AI가 코디를 고르고 있어요...',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
        ),
      );
    }

    // 실패 → 안내 + 재시도 버튼
    if (_error) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          children: [
            const Icon(Icons.sentiment_dissatisfied,
                color: Colors.black26, size: 40),
            const SizedBox(height: 10),
            const Text(
              '추천을 불러오지 못했어요. 다시 시도',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => _fetchRecommendation(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF534AB7),
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
        ),
      );
    }

    // 정상 → 카드 목록 (name 비어있던 항목은 이미 제외됨)
    return Column(
      children: _items.map(_buildCoordiCard).toList(),
    );
  }

  // 추천 코디 카드 1개
  Widget _buildCoordiCard(_CoordiItem item) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EFE8),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          // 썸네일 — 매칭된 옷장 이미지가 있으면 표시, 없으면 아이콘 fallback
          Container(
            width: 50,
            height: 50,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
            ),
            child: item.imagePath != null
                ? Image.file(
                    File(item.imagePath!),
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                    // 디코딩 실패 등 예외 시에도 아이콘으로 fallback
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.checkroom, color: Colors.black26),
                  )
                : const Icon(Icons.checkroom, color: Colors.black26),
          ),
          const SizedBox(width: 12),
          // 라벨 + 이름 + 이유
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      item.label,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF534AB7),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _ownedBadge(item.owned),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  item.name,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.reason.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.reason,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.black54),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.black26),
        ],
      ),
    );
  }

  // 보유 / 추천 구매 뱃지
  Widget _ownedBadge(bool owned) {
    final bg = owned ? const Color(0xFFE3F1E6) : const Color(0xFFEEEDFE);
    final fg = owned ? const Color(0xFF2E7D43) : const Color(0xFF534AB7);
    final text = owned ? '보유' : '추천 구매';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
