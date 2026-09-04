# MOIP-Z (모입지)

> "오늘 뭐 입지?" — 옷장 관리부터 AI 코디 추천, 가상 피팅까지

## 소개

MOIP-Z는 사용자의 옷장을 디지털로 관리하고, AI가 상황에 맞는 코디를 추천하며,
자신의 사진으로 가상 피팅까지 해볼 수 있는 안드로이드 앱입니다.

기존 가상 피팅 서비스가 브랜드의 상품 이미지 제작에 초점이 맞춰져 있는 것과 달리,
MOIP-Z는 사용자 본인의 사진과 실제 체형을 기준으로 한 개인용 피팅을 지향합니다.

## 앱 시연 영상

https://www.youtube.com/shorts/bD1kWd607l0

## 주요 기능

| 기능 | 설명 |
|---|---|
| 옷장 관리 | 보유 의류를 촬영·등록하고 카테고리별로 관리 |
| AI 코디 추천 | 날씨와 일정에 맞는 조합을 AI가 제안 |
| 가상 피팅 | 사용자 사진에 의류를 합성해 착용 모습 확인 |
| 가격 비교 | 네이버 쇼핑 API 연동으로 유사 상품 탐색 |

## 기술 스택

- **Frontend** — Flutter (Dart)
- **Backend** — Node.js
- **AI 추천** — Gemini API
- **가상 피팅** — fal.ai Kolors v1.5 / FASHN.ai (검토 중)
- **외부 API** — 네이버 쇼핑 API, 기상청 API

민감한 생체 정보는 온디바이스에서 처리하여 개인정보보호법상 노출을 최소화하는 구조로
설계하였습니다.

## 개발 환경 세팅

### 요구 사항
- Flutter 3.47.2 (stable)
- Android SDK 36 이상
- 실제 안드로이드 기기 또는 에뮬레이터

### ⚠️ Windows 한글 경로 주의

사용자 계정명에 한글이 포함된 경우(`C:\Users\홍길동`) Gradle 빌드가 실패합니다.
아래 경로를 모두 ASCII 경로로 지정해야 합니다.

| 항목 | 권장 경로 |
|---|---|
| Flutter SDK | `C:\src\flutter` |
| 프로젝트 | `C:\src\projects\MOIPZ-flutter` |
| Pub 캐시 | `C:\src\pub-cache` |
| Gradle 캐시 | `C:\src\gradle` |

환경 변수(사용자 변수)에 `PUB_CACHE`, `GRADLE_USER_HOME`을 위 값으로 등록하고,
`Path` 안에 `C:\src\flutter\bin` 항목을 추가합니다.

### 실행

```bash
flutter pub get
flutter devices
flutter run
```

실행 중 단축키: `r` (hot reload) / `R` (hot restart) / `q` (종료)

## 알려진 이슈

- **NDK 비활성화 상태** — `sdkmanager.bat`이 한글이 포함된 SDK 경로에서 크래시하여
  `android/app/build.gradle.kts`의 `ndkVersion`을 주석 처리하였습니다.
  카메라·이미지 처리 플러그인 도입 시 SDK를 ASCII 경로로 이전하고 재활성화가 필요합니다.
- Gradle 8.14 / AGP 8.11.1 / Kotlin 2.2.20 — 지원 종료 예정 경고가 출력되지만
  현재 빌드에는 영향이 없습니다.
