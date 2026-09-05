# MOIP-Z (모입지) — Flutter
> 초기 SvelteKit 프로토타입을 Flutter로 재구현한 버전입니다.

> "오늘 뭐 입지?" — 옷장 관리부터 AI 코디 추천, 가상 피팅까지

![Flutter](https://img.shields.io/badge/Flutter-3.47.2-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)
![Android](https://img.shields.io/badge/Android-SDK%2036+-3DDC84?logo=android&logoColor=white)
![Gemini](https://img.shields.io/badge/Gemini-API-8E75B2?logo=googlegemini&logoColor=white)

## 앱 시연 영상

https://www.youtube.com/shorts/bD1kWd607l0

## 기술 스택

| 구분 | 사용 기술 |
|---|---|
| **Frontend** | Flutter (Dart) |
| **Backend** | Node.js *(분리 예정)* |
| **AI 추천** | Gemini API |
| **가상 피팅** | fal.ai Kolors v1.5 / FASHN.ai *(검토 중)* |
| **외부 API** | 네이버 쇼핑 API, 기상청 API |

민감한 생체 정보는 온디바이스에서 처리하여 개인정보보호법상 노출을 최소화하는
구조로 설계하였습니다.

## 개발 환경

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
