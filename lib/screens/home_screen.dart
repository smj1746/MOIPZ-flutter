import 'secrets.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ★ 같은 폴더 안의 다른 화면 파일들을 import
//    home_screen에서 Navigator.push로 이 화면들을 호출하기 때문에 필요
import 'cody_screen.dart';
import 'gemini_test_screen.dart';
import 'profile_screen.dart';
import 'virtual_fitting_screen.dart';
import 'wardrobe_screen.dart';


// 위치 fallback (안양)
const double _fallbackLat = 37.3943;
const double _fallbackLon = 126.9568;

// 날씨 조회 결과를 담는 간단한 값 객체
class _Weather {
  final int temp; // 섭씨, 반올림
  final String condition; // 한글 상태

  const _Weather({required this.temp, required this.condition});
}

// 상품 1개를 담는 값 객체 (네이버 쇼핑 / 더미 공통)
class _Product {
  final String title; // 상품명 (HTML 태그/엔티티 제거됨)
  final String image; // 상품 이미지 URL (비어있으면 placeholder 아이콘)
  final int price;    // 최저가 (lprice)
  final String mall;  // 쇼핑몰명 (mallName)

  const _Product({
    required this.title,
    required this.image,
    required this.price,
    required this.mall,
  });
}

// 실연동 실패 시 대체할 더미 상품 (데모 안전장치)
const List<_Product> _dummyProducts = [
  _Product(title: '스프링 데일리 셔츠', image: '', price: 29000, mall: '무신사'),
  _Product(title: '베이직 코튼 팬츠', image: '', price: 39000, mall: '29CM'),
];

// ──────────────────────────────────────────────────────────────
// 홈 화면 (StatefulWidget — 하단 네비게이션 선택 상태 + 날씨 상태 관리)
// ──────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0; // 현재 선택된 하단 탭

  // ── 날씨 카드 상태 ──────────────────────────────
  bool _weatherLoading = true; // 로딩 중이면 스피너 표시
  String _location = '안양'; // 표시할 지명
  int _temp = 25; // 기온(℃)
  String _condition = '맑음'; // 한글 상태

  // ── 이달의 상품 상태 (네이버 쇼핑) ───────────────
  bool _productsLoading = true;
  List<_Product> _products = [];

  @override
  void initState() {
    super.initState();
    // ★ initState에서 1회만 호출 → 테스트는 Hot Restart로 해야 반영됨
    _loadWeather();
  }

  // ════════════════════════════════════════════════════════════
  // 날씨 로딩 메인 플로우
  //   1) geolocator로 현재 위치 (실패 시 안양 fallback)
  //   2) geocoding으로 한글 지명 (실패 시 좌표 표시)
  //   3) OpenWeatherMap(1순위) → 401/오류면 Open-Meteo(2순위)로 fallback
  //      → 둘 다 실패하면 안양 18° 맑음 더미(3순위)
  // ════════════════════════════════════════════════════════════
  Future<void> _loadWeather() async {
    // 1) 위치 확보
    final ({double lat, double lon}) pos = await _determinePosition();

    // 2) 지명 (병렬로 받아도 되지만 순차로 단순하게)
    final place = await _resolvePlaceName(pos.lat, pos.lon);

    // 3) 날씨: OWM 우선 → Open-Meteo fallback → 더미
    _Weather? weather;
    try {
      weather = await _fetchOwm(pos.lat, pos.lon);
    } catch (_) {
      weather = null; // 네트워크 예외 등 → 다음 단계로
    }
    if (weather == null) {
      try {
        weather = await _fetchOpenMeteo(pos.lat, pos.lon);
      } catch (_) {
        weather = null;
      }
    }
    // 최종 fallback: 안양25° 맑음 더미
    weather ??= const _Weather(temp: 25, condition: '맑음');

    if (!mounted) return;
    setState(() {
      _location = place;
      _temp = weather!.temp;
      _condition = weather.condition;
      _weatherLoading = false;
    });

    // ★ 날씨 로딩 이후 1회 — 기온/상태 기반 키워드로 '이달의 상품' 조회
    await _loadProducts();
  }

  // ════════════════════════════════════════════════════════════
  // 이달의 상품 — 네이버 쇼핑 검색 (실연동 우선, 실패 시 더미 fallback)
  //   키워드: 현재 기온/상태 + (가능하면) user_profile 성별 접두어
  // ════════════════════════════════════════════════════════════
  Future<void> _loadProducts() async {
    // 프로필 성별 읽기 (실패해도 무시)
    String gender = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_profile');
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        gender = (m['gender'] ?? '').toString();
      }
    } catch (_) {/* 성별 못 읽어도 키워드 생성엔 지장 없음 */}

    final keyword = _productKeyword(_temp, _condition, gender);
    final products = await _fetchNaverShopping(keyword);

    if (!mounted) return;
    setState(() {
      _products = products;
      _productsLoading = false;
    });
  }

  // ── 기온/상태(+성별) → 검색 키워드 1개 ───────────
  String _productKeyword(int temp, String condition, String gender) {
    // 비/소나기/뇌우면 방수 우선
    final wet = condition.contains('비') ||
        condition.contains('소나기') ||
        condition.contains('뇌우');

    String base;
    if (wet) {
      base = '방수 자켓';
    } else if (temp < 10) {
      base = '코트';
    } else if (temp >= 27) {
      base = '린넨 셔츠';
    } else {
      base = '캐주얼 셔츠';
    }

    // 성별 접두어 (남/여만 반영, 그 외엔 생략)
    final prefix = gender == '남'
        ? '남성 '
        : gender == '여'
            ? '여성 '
            : '';
    return '$prefix$base';
  }

  // ── 네이버 쇼핑 호출 → 상품 목록 (어떤 실패든 더미 반환) ──
  //   더미 대체 조건: 자격증명 비어있음 / 네트워크 실패 / 401·403 /
  //                  items 비어있음 / 파싱 실패
  Future<List<_Product>> _fetchNaverShopping(String keyword) async {
    // 자격증명이 비어있거나 placeholder 그대로면 호출 스킵 → 더미
    final idReady = naverClientId.isNotEmpty && !naverClientId.startsWith('여기에');
    final secretReady =
        naverClientSecret.isNotEmpty && !naverClientSecret.startsWith('여기에');
    if (!idReady || !secretReady) return _dummyProducts;

    try {
      final url = Uri.parse(
        'https://openapi.naver.com/v1/search/shop.json'
        '?query=${Uri.encodeQueryComponent(keyword)}&display=2&sort=sim',
      );
      final res = await http.get(
        url,
        headers: {
          'X-Naver-Client-Id': naverClientId,
          'X-Naver-Client-Secret': naverClientSecret,
        },
      ).timeout(const Duration(seconds: 8));

      // 401/403 등 비정상 응답 → 더미
      if (res.statusCode != 200) return _dummyProducts;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = data['items'] as List<dynamic>?;
      if (items == null || items.isEmpty) return _dummyProducts;

      final products = <_Product>[];
      for (final it in items.take(2)) {
        if (it is! Map) continue;
        final title = _stripHtml((it['title'] ?? '').toString());
        if (title.isEmpty) continue;
        products.add(_Product(
          title: title,
          image: (it['image'] ?? '').toString(),
          price: int.tryParse((it['lprice'] ?? '').toString()) ?? 0,
          mall: (it['mallName'] ?? '').toString(),
        ));
      }
      // 유효 항목이 없으면 더미
      return products.isEmpty ? _dummyProducts : products;
    } catch (_) {
      // 네트워크/파싱 등 어떤 예외든 더미 (앱이 안 죽게)
      return _dummyProducts;
    }
  }

  // 네이버 title의 <b> 등 HTML 태그 및 &amp; 같은 엔티티 제거
  String _stripHtml(String s) {
    var t = s.replaceAll(RegExp(r'<[^>]*>'), '');
    t = t
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
    return t.trim();
  }

  // 천단위 콤마 (예: 29000 → 29,000)
  String _formatPrice(int price) {
    final s = price.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  // ── 1) 현재 위치 (실패하면 안양 좌표) ────────────
  //   위치 서비스 꺼짐 / 권한 거부 / 영구거부를 각각 처리
  Future<({double lat, double lon})> _determinePosition() async {
    const fallback = (lat: _fallbackLat, lon: _fallbackLon);
    try {
      // 위치 서비스(GPS) 자체가 꺼져 있으면 fallback
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return fallback;

      // 권한 확인 → 거부 상태면 1회 요청
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return fallback;
      }
      // 영구 거부면 요청 자체가 불가 → fallback
      if (permission == LocationPermission.deniedForever) return fallback;

      // 현재 위치 (저정확도로 빠르게)
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
        ),
      );
      return (lat: p.latitude, lon: p.longitude);
    } catch (_) {
      // 타임아웃 등 어떤 예외든 fallback
      return fallback;
    }
  }

  // ── 2) 좌표 → 한글 시/구 지명 ────────────────────
  Future<String> _resolvePlaceName(double lat, double lon) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lon);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        // 시·도(administrativeArea) + 시·군·구(locality 우선, 없으면 subAdministrativeArea)
        final city = p.administrativeArea ?? '';
        final district = (p.locality != null && p.locality!.isNotEmpty)
            ? p.locality!
            : (p.subAdministrativeArea ?? '');
        final name =
            [city, district].where((s) => s.isNotEmpty).join(' ').trim();
        if (name.isNotEmpty) return name;
      }
    } catch (_) {
      // geocoding 실패(에뮬레이터/네트워크 등) → 좌표 표시로 fallback
    }
    return '${lat.toStringAsFixed(2)}, ${lon.toStringAsFixed(2)}';
  }

  // ── 3-a) OpenWeatherMap Current Weather ──────────
  //   401(키 미활성) 등 200이 아니면 null 반환 → 호출부에서 Open-Meteo로 fallback
  Future<_Weather?> _fetchOwm(double lat, double lon) async {
    final url = Uri.parse(
      'https://api.openweathermap.org/data/2.5/weather'
      '?lat=$lat&lon=$lon&appid=$owmApiKey&units=metric&lang=kr',
    );
    final res = await http.get(url).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      // 401(키 미활성/오류) 포함 모든 비정상 응답은 fallback 대상
      return null;
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final temp = (data['main']?['temp'] as num?)?.round();
    final weatherList = data['weather'] as List<dynamic>?;
    final desc = (weatherList != null && weatherList.isNotEmpty)
        ? weatherList.first['description']?.toString()
        : null;
    if (temp == null) return null;
    return _Weather(temp: temp, condition: desc ?? '날씨 정보');
  }

  // ── 3-b) Open-Meteo (키 불필요) fallback ─────────
  Future<_Weather?> _fetchOpenMeteo(double lat, double lon) async {
    final url = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code',
    );
    final res = await http.get(url).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final current = data['current'] as Map<String, dynamic>?;
    if (current == null) return null;
    final temp = (current['temperature_2m'] as num?)?.round();
    final code = (current['weather_code'] as num?)?.toInt();
    if (temp == null) return null;
    return _Weather(temp: temp, condition: _wmoToKr(code ?? 0));
  }

  // ── Open-Meteo WMO weather_code → 한글 상태 ──────
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

  // ── 기온 기반 간단 옷차림 추천 (카드 우측 문구) ──
  String _recommendation(int temp) {
    if (temp >= 28) return '민소매·반팔로\n시원하게 입어요';
    if (temp >= 23) return '반팔·얇은 셔츠를\n추천해요';
    if (temp >= 20) return '얇은 가디건·\n긴팔을 추천해요';
    if (temp >= 17) return '가벼운 자켓과\n긴팔 셔츠를 추천해요';
    if (temp >= 12) return '자켓·니트로\n가볍게 입어요';
    if (temp >= 9) return '트렌치코트·\n야상을 추천해요';
    if (temp >= 5) return '코트·두꺼운\n니트를 추천해요';
    return '패딩·두꺼운\n외투를 추천해요';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,

      // ── AppBar ──────────────────────────────

      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        title: const Text(
          'MOIP-Z',
          style: TextStyle(
            color: Color(0xFF534AB7),
            fontWeight: FontWeight.w600,
            fontSize: 18,
            letterSpacing: 1.0,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.api, color: Colors.black54),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GeminiTestScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.notifications_none, color: Colors.black54),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.search, color: Colors.black54),
            onPressed: () {},
          ),
        ],
      ),

      // ── Body (스크롤 가능한 메인 컨텐츠) ────
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildGreeting(),         // 인사말
            const SizedBox(height: 12),
            _buildWeatherCard(),      // 날씨 카드
            const SizedBox(height: 18),
            _buildQuickMenu(),        // 3대 핵심 기능 빠른 진입
            const SizedBox(height: 22),
            _buildTodayCoordi(),      // 오늘의 추천 코디
            const SizedBox(height: 22),
            _buildMonthlyProduct(),   // 이달의 상품
            const SizedBox(height: 24),
          ],
        ),
      ),

      // ── 하단 네비게이션 바 ───────────────────
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          // 1. 먼저 선택된 탭 인덱스 업데이트 (탭 색상이 보라색으로 바뀜)
          setState(() {
            _selectedIndex = index;
          });

          // 2. 인덱스에 따라 해당 화면으로 이동
          //    인덱스 0(홈)은 현재 화면이라 이동 안 함
          //    인덱스 3(내정보)는 아직 화면이 없어서 SnackBar로 안내
          if (index == 1) {
            // 옷장 화면으로 이동
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WardrobeScreen()),
            ).then((_) {
              // ★ 뒤로가기로 홈에 돌아오면 탭 강조를 '홈(0)'으로 복귀
              setState(() {
                _selectedIndex = 0;
              });
            });
          } else if (index == 2) {
            // AI 코디 추천 화면으로 이동 (이미 불러온 날씨 값 재사용)
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CodyScreen(
                  initialTemp: _temp,
                  initialCondition: _condition,
                ),
              ),
            ).then((_) {
              // 뒤로가기시 탭 강조를 '홈(0)'으로 복귀
              setState(() {
                _selectedIndex = 0;
              });
            });
          } else if (index == 3) {
            // 내정보 화면으로 이동
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ).then((_) {
              // 뒤로가기시 탭 강조를 '홈(0)'으로 복귀
              setState(() {
                _selectedIndex = 0;
              });
            });
          }
        },
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF534AB7),
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: '홈'),
          BottomNavigationBarItem(icon: Icon(Icons.checkroom), label: '옷장'),
          BottomNavigationBarItem(icon: Icon(Icons.auto_awesome), label: '추천'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: '내정보'),
        ],
      ),
    );
  }

  // ── 1) 인사말 ─────────────────────────────────
  Widget _buildGreeting() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('안녕하세요',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          SizedBox(height: 4),
          Text('신민종님',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('오늘도 멋진 하루 보내세요',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        ],
      ),
    );
  }

  // ── 2) 날씨 카드 (실제 데이터) ─────────────────
  //   형식: [날짜 · 위치] / [기온°] / [상태]
  //   기존 디자인/레이아웃 유지, 값만 실제 데이터로. 로딩 중엔 스피너.
  Widget _buildWeatherCard() {
    final now = DateTime.now();
    final dateStr = '${now.month}월 ${now.day}일';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE6F1FB),
        borderRadius: BorderRadius.circular(12),
      ),
      child: _weatherLoading
          // ── 로딩 중: 카드 안에 스피너 ──
          ? const SizedBox(
              height: 92,
              child: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Color(0xFF185FA5),
                  ),
                ),
              ),
            )
          // ── 로딩 완료: 실제 값 ──
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // [날짜 · 위치]
                      Text('$_location · $dateStr',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF185FA5))),
                      const SizedBox(height: 6),
                      // [기온°]
                      Text('$_temp°',
                          style: const TextStyle(
                              fontSize: 28,
                              color: Color(0xFF0C447C),
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      // [상태]
                      Text(_condition,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF185FA5))),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 기온 기반 옷차림 추천 문구
                Text(
                  _recommendation(_temp),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF185FA5),
                    height: 1.5,
                  ),
                ),
              ],
            ),
    );
  }

  // ── 3) 빠른 메뉴 (옷장 / AI 코디 / 가상 피팅) ─
  Widget _buildQuickMenu() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(child: _menuItem(Icons.checkroom, '내 옷장', false)),
          const SizedBox(width: 8),
          Expanded(child: _menuItem(Icons.auto_awesome, 'AI 코디', true)),
          const SizedBox(width: 8),
          Expanded(
              child: _menuItem(Icons.face_retouching_natural, '가상 피팅', false)),
        ],
      ),
    );
  }

  Widget _menuItem(IconData icon, String label, bool highlight) {
    return GestureDetector(
      onTap: () {
        // ── 어떤 메뉴를 눌렀는지에 따라 이동할 화면 결정 ──
        Widget targetScreen;
        if (label == '내 옷장') {
          targetScreen = const WardrobeScreen();
        } else if (label == 'AI 코디') {
          // 이미 불러온 날씨 값 재사용
          targetScreen =
              CodyScreen(initialTemp: _temp, initialCondition: _condition);
        } else {
          targetScreen = const VirtualFittingScreen();
        }

        // Navigator.push: 현재 화면 위에 새 화면을 쌓아 올림
        // MaterialPageRoute: 머티리얼 디자인 슬라이드 전환 + 뒤로가기 자동 생성
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => targetScreen),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: highlight
              ? const Color(0xFFEEEDFE)
              : const Color(0xFFF1EFE8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon,
                size: 26,
                color: highlight ? const Color(0xFF534AB7) : Colors.black54),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: highlight ? const Color(0xFF3C3489) : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 4) 오늘의 추천 코디 ───────────────────────
  Widget _buildTodayCoordi() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('오늘의 추천 코디',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text('더보기',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _coordiCard('캐주얼')),
              const SizedBox(width: 8),
              Expanded(child: _coordiCard('데일리')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _coordiCard(String label) {
    return Container(
      height: 160,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EFE8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
      ),
    );
  }

  // ── 5) 이달의 상품 (네이버 쇼핑) ──────────────
  Widget _buildMonthlyProduct() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('이달의 상품',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (_productsLoading)
            // 로딩 중 스피너
            Container(
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF1EFE8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.2, color: Color(0xFF534AB7)),
              ),
            )
          else
            // 상품 카드 1~2개 (카드 사이 간격)
            Column(
              children: [
                for (var i = 0; i < _products.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _buildProductCard(_products[i]),
                ],
              ],
            ),
        ],
      ),
    );
  }

  // 상품 카드 1개
  Widget _buildProductCard(_Product p) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EFE8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // 상품 이미지 (네트워크) — 로딩/실패 시 placeholder 아이콘
          Container(
            width: 44,
            height: 44,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black12),
            ),
            child: p.image.isNotEmpty
                ? Image.network(
                    p.image,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    loadingBuilder: (ctx, child, progress) =>
                        progress == null
                            ? child
                            : const Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              ),
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.image_outlined,
                        color: Colors.black26),
                  )
                : const Icon(Icons.image_outlined, color: Colors.black26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatPrice(p.price)}원${p.mall.isNotEmpty ? ' · ${p.mall}' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
