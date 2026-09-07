import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ──────────────────────────────────────────────────────────────
// 내 정보 화면 (StatefulWidget)
//  - 기본정보 카드 + 민감정보 카드 두 섹션으로 구성
//  - '저장' 버튼 → shared_preferences에 'user_profile' 키로 JSON 저장
//  - 화면 진입(initState) 시 기존 값이 있으면 각 입력칸에 복원
//
//  ★ JSON 키 이름은 AI 코디 화면이 동일하게 읽으므로 절대 변경 금지:
//    nickname, gender, ageGroup, height, weight,
//    bodyType, preferredStyle, skinTone
// ──────────────────────────────────────────────────────────────
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // shared_preferences 저장 키
  static const String _prefsKey = 'user_profile';

  // 브랜드 컬러 (앱 전반에서 쓰는 보라색)
  static const Color _brand = Color(0xFF534AB7);

  // ── 텍스트 입력 컨트롤러 ─────────────────────
  final TextEditingController _nicknameCtrl = TextEditingController();
  final TextEditingController _heightCtrl = TextEditingController();
  final TextEditingController _weightCtrl = TextEditingController();

  // ── 드롭다운 선택값 (null = 미선택) ──────────
  String? _gender;
  String? _ageGroup;
  String? _bodyType;
  String? _preferredStyle;
  String? _skinTone;

  // ── 드롭다운 선택지 정의 ─────────────────────
  static const List<String> _genderOptions = ['남', '여', '기타'];
  static const List<String> _ageGroupOptions = [
    '10대', '20대', '30대', '40대', '50대', '60대+',
  ];
  static const List<String> _bodyTypeOptions = ['마름', '보통', '통통', '근육질'];
  static const List<String> _styleOptions = [
    '캐주얼', '미니멀', '스트릿', '클래식', '스포티',
  ];
  static const List<String> _skinToneOptions = ['봄웜', '여름쿨', '가을웜', '겨울쿨'];

  @override
  void initState() {
    super.initState();
    _loadProfile(); // 진입 시 기존 저장값 복원
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  // ── 저장된 프로필 복원 ───────────────────────
  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;

    try {
      final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;

      setState(() {
        _nicknameCtrl.text = (data['nickname'] ?? '').toString();
        _heightCtrl.text = (data['height'] ?? '').toString();
        _weightCtrl.text = (data['weight'] ?? '').toString();

        // 드롭다운은 유효한 선택지일 때만 복원 (잘못된 값이면 무시)
        _gender = _validOrNull(data['gender'], _genderOptions);
        _ageGroup = _validOrNull(data['ageGroup'], _ageGroupOptions);
        _bodyType = _validOrNull(data['bodyType'], _bodyTypeOptions);
        _preferredStyle = _validOrNull(data['preferredStyle'], _styleOptions);
        _skinTone = _validOrNull(data['skinTone'], _skinToneOptions);
      });
    } catch (_) {
      // 손상된 JSON이면 조용히 무시 (빈 폼으로 시작)
    }
  }

  // 값이 선택지 목록에 있으면 그대로, 아니면 null 반환
  String? _validOrNull(dynamic value, List<String> options) {
    final str = value?.toString();
    return (str != null && options.contains(str)) ? str : null;
  }

  // ── 프로필 저장 ──────────────────────────────
  Future<void> _saveProfile() async {
    final profile = <String, String>{
      'nickname': _nicknameCtrl.text.trim(),
      'gender': _gender ?? '',
      'ageGroup': _ageGroup ?? '',
      'height': _heightCtrl.text.trim(),
      'weight': _weightCtrl.text.trim(),
      'bodyType': _bodyType ?? '',
      'preferredStyle': _preferredStyle ?? '',
      'skinTone': _skinTone ?? '',
    };

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(profile));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('내 정보가 저장되었어요'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: Colors.black54),
        title: const Text(
          '내 정보',
          style: TextStyle(
            color: _brand,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 기본정보 카드 ──────────────────
            _buildSectionCard(
              title: '기본 정보',
              children: [
                _buildTextField(
                  label: '닉네임',
                  controller: _nicknameCtrl,
                  hint: '닉네임을 입력하세요',
                ),
                const SizedBox(height: 16),
                _buildDropdown(
                  label: '성별',
                  value: _gender,
                  options: _genderOptions,
                  onChanged: (v) => setState(() => _gender = v),
                ),
                const SizedBox(height: 16),
                _buildDropdown(
                  label: '연령대',
                  value: _ageGroup,
                  options: _ageGroupOptions,
                  onChanged: (v) => setState(() => _ageGroup = v),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── 민감정보 카드 ──────────────────
            _buildSectionCard(
              title: '민감 정보',
              children: [
                _buildTextField(
                  label: '키 (cm)',
                  controller: _heightCtrl,
                  hint: '예: 175',
                  numeric: true,
                ),
                const SizedBox(height: 16),
                _buildTextField(
                  label: '몸무게 (kg)',
                  controller: _weightCtrl,
                  hint: '예: 68',
                  numeric: true,
                ),
                const SizedBox(height: 16),
                _buildDropdown(
                  label: '체형',
                  value: _bodyType,
                  options: _bodyTypeOptions,
                  onChanged: (v) => setState(() => _bodyType = v),
                ),
                const SizedBox(height: 16),
                _buildDropdown(
                  label: '선호 스타일',
                  value: _preferredStyle,
                  options: _styleOptions,
                  onChanged: (v) => setState(() => _preferredStyle = v),
                ),
                const SizedBox(height: 16),
                _buildDropdown(
                  label: '피부톤',
                  value: _skinTone,
                  options: _skinToneOptions,
                  onChanged: (v) => setState(() => _skinTone = v),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ── 저장 버튼 ──────────────────────
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  '저장',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 섹션 카드 래퍼 ───────────────────────────
  Widget _buildSectionCard({
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      elevation: 0,
      color: const Color(0xFFF7F6FC),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: _brand,
              ),
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }

  // ── 라벨 + 텍스트 입력 ───────────────────────
  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool numeric = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(label),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          inputFormatters: numeric
              ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
              : null,
          decoration: _inputDecoration(hint),
        ),
      ],
    );
  }

  // ── 라벨 + 드롭다운 ──────────────────────────
  Widget _buildDropdown({
    required String label,
    required String? value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(label),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: _inputDecoration('선택하세요'),
          items: options
              .map((o) => DropdownMenuItem<String>(
                    value: o,
                    child: Text(o),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  // 입력 필드 공통 라벨 스타일
  Widget _fieldLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: Colors.black87,
      ),
    );
  }

  // 입력 필드 공통 데코레이션
  InputDecoration _inputDecoration(String? hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.black38, fontSize: 13),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE0DEEC)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _brand, width: 1.4),
      ),
    );
  }
}
