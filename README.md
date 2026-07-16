# growing pots — 아이패드 인생네컷 앱 (구 GROWING CUT)

아이패드로 찍는 셀프 네컷 부스입니다. 졸업식 컨셉 "growing pots" 디자인(Figma 시안 1:1 재현)이 적용되어 있어요. (아이폰에서도 실행됩니다 — 세로 고정, 카메라 흐름 테스트 용도로 유용해요.)

**흐름:** 홈 → `촬영 시작` → 전면 카메라가 5초 타이머로 6컷 자동 촬영(각 컷 동안 영상도 함께 녹화) → 6컷 중 4컷 선택 + 프레임(라임/블랙/화이트) 선택 — **40초 제한, 만료 시 자동 진행** → 네컷 합성(우측 상단 QR 포함) → 업로드 대기 중 Instagram/랜딩 QR 노출 → 완료 화면 QR → 휴대폰으로 QR을 찍으면 **4시간짜리 임시 링크**에서 네컷 사진과 '움직이는 네컷' 영상을 저장할 수 있어요.

```
growingcut/
├── ios/                 # 아이패드 앱 (SwiftUI, iOS 17+, 세로 고정)
│   ├── GrowingCut.xcodeproj
│   ├── GrowingCut/
│   │   ├── App/         # 앱 진입점, 화면 흐름 상태
│   │   ├── Views/       # 홈 / 촬영 / 선택 / 결과(생성중·대기·완료) / 설정
│   │   ├── Camera/      # AVCaptureSession (사진 + 클립 동시 캡처)
│   │   ├── Rendering/   # 네컷 합성 코어 (iOS/macOS 공용, UIKit 무의존)
│   │   ├── Networking/  # 업로드 클라이언트
│   │   └── Resources/   # 프레임 오버레이 PNG · UI 에셋 · Pretendard 폰트
│   └── Support/Info.plist
├── server/              # 4시간 임시 링크 공유 서버 (Node 18+, 무의존)
├── vercel/              # 프로덕션 공유 서버 (Vercel + Blob)
└── tools/               # macOS 검증 도구 (합성 결과 확인용)
```

## 실행 방법

공유 서버는 두 가지 방식 중 하나로 운영합니다:

| | 로컬 서버 (`server/`) | Vercel 배포 (`vercel/`) |
|---|---|---|
| 요건 | 맥이 켜져 있고 같은 와이파이 | 무료 Vercel 계정 |
| QR 접속 | 같은 와이파이에서만 | **어디서든 (셀룰러 포함)** |
| 만료 처리 | 접근 시 410 + 30분마다 정리 | 접근 시 410+즉시 삭제 + 크론 정리 |

### 0) Vercel로 배포하기 (권장 — 어디서든 QR이 열림)

```bash
cd vercel
npx vercel login          # 브라우저에서 로그인 (1회)
npx vercel link           # 프로젝트 생성/연결 (1회)
npx vercel deploy --prod
```

1회 설정: Vercel 대시보드 → 프로젝트 → **Storage → Blob store 생성 후 연결** (BLOB_READ_WRITE_TOKEN이 자동 주입됩니다).
선택 설정(환경변수): `GC_UPLOAD_KEY`(아무나 업로드 못 하게 하는 키 — 앱 ⚙️의 '업로드 키'에 같은 값 입력), `TTL_HOURS`(기본 4), `CRON_SECRET`(크론 보호).

앱 ⚙️ 설정에 `https://<프로젝트명>.vercel.app`을 입력하면 끝. 영상은 서버리스 요청 한도(4.5MB) 안에 들도록 비트레이트가 캡되어 있어요(5초 ≈ 2.2MB).
참고: Hobby 플랜 크론은 하루 1회까지라 `vercel.json`의 스케줄이 daily로 되어 있습니다. 만료 정확성은 페이지 접근 시점에 항상 강제되므로(410 + 즉시 삭제) 크론은 용량 회수용입니다.

### 1) 공유 서버 켜기 (맥)

```bash
node server/server.js
```

시작하면 앱에 입력할 주소가 출력됩니다. 예:

```
앱 설정(⚙️)에 아래 주소 중 하나를 입력하세요:
  http://localhost:8787      (시뮬레이터 전용)
  http://192.168.0.10:8787   (en0 — 실기기/휴대폰용)
```

- 업로드된 사진·영상은 **4시간 뒤 자동 삭제**됩니다 (`TTL_HOURS`, `PORT`, `DATA_DIR` 환경변수로 조절).
- 인증이 없는 **같은 와이파이(LAN) 데모용** 서버입니다. 공용 인터넷에 그대로 노출하지 마세요.

### 2) 앱 실행 (아이패드 / 아이폰)

1. `ios/GrowingCut.xcodeproj`를 Xcode(16+)로 엽니다.
2. Signing & Capabilities에서 팀만 선택하고 기기에 실행합니다.
3. 앱 메인 화면 우측 상단 ⚙️에서 서버 주소(위 LAN 주소)를 입력하고 `연결 테스트`로 확인합니다.
4. 촬영 기기와 QR을 찍을 휴대폰이 **같은 와이파이**에 있어야 링크가 열립니다.

Xcode 없이 CLI로 실기기에 설치하려면 (기기 USB 연결 + 개발자 모드 필요):

```bash
cd ios
xcodebuild -project GrowingCut.xcodeproj -target GrowingCut -configuration Debug \
  -sdk iphoneos DEVELOPMENT_TEAM=<팀ID> \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl list devices                # 기기 식별자 확인
xcrun devicectl device install app --device <식별자> build/Debug-iphoneos/GrowingCut.app
```

처음 설치라면 아이폰의 `설정 → 일반 → VPN 및 기기 관리`에서 개발자 앱을 신뢰해야 실행됩니다.

시뮬레이터에는 카메라가 없으므로 메인 화면의 **`데모 촬영`** 버튼으로 전체 흐름(합성→업로드→QR)을 확인할 수 있습니다.

CLI 빌드:

```bash
cd ios
xcodebuild -project GrowingCut.xcodeproj -target GrowingCut \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

## 촬영 규칙 (기본값)

| 항목 | 값 | 위치 |
|---|---|---|
| 촬영 컷 수 | 6컷 | `AppModel.shotCount` |
| 컷당 타이머 | 5초 | `AppModel.countdownSeconds` |
| 선택 컷 수 | 4컷 (제한 40초, 만료 시 자동 채움) | `AppModel.pickCount` / `selectionSeconds` |
| 링크 유효 시간 | 4시간 | 서버 `TTL_HOURS` |
| 이미지 | 1080×1920 JPEG, QR 우측 상단 (862.84, 63) | `LayoutSpec` |
| 영상 | 540×960 30fps H.264, 길이 = 가장 짧은 클립 | `VideoComposer` |

**프레임 시스템 (오버레이 PNG):** 프레임 디자인은 슬롯 4개(각 480×675.5)와 QR 창이 투명하게 뚫린 1080×1920 PNG(`ios/GrowingCut/Resources/Frames/frame-*.png`)입니다. 렌더러는 사진을 슬롯 아래에 깔고 오버레이를 덮은 뒤 QR을 그립니다. **프레임 추가 = 오버레이 PNG 1장 + 썸네일 + `FrameStyle.all` 1줄.** 스틸과 영상 오버레이가 같은 렌더러(`FrameRenderer`)를 씁니다. 현재 3종: 라임/블랙/화이트 (Figma 시안).

## 검증 도구 (macOS)

카메라·기기 없이 합성 코어를 검증합니다.

```bash
# 오버레이 알파 검증 + 합성 스틸(3종) + 움직이는 네컷 + QR 디코드 + 프레임 추출
xcrun swiftc -parse-as-library -O -o /tmp/preview tools/preview.swift ios/GrowingCut/Rendering/*.swift
/tmp/preview /tmp/preview-out ios/GrowingCut/Resources/Frames

# 영상 파일 길이/크기/프레임 확인, 이미지 QR 디코드
xcrun swiftc -parse-as-library -O -o /tmp/probe tools/probe.swift
/tmp/probe <영상.mp4> <출력 디렉터리>
/tmp/probe --qr <이미지.jpg>
```

시뮬레이터 자동 데모 (UI 조작 없이 파이프라인 실행):

```bash
xcrun simctl launch <UDID> com.growingcut.app -autoDemo     # 곧장 결과 화면까지
xcrun simctl launch <UDID> com.growingcut.app -demoSelect   # 선택 화면까지
```

## 구현 노트

- **영상 합성은 AVAssetReader → CoreImage → AVAssetWriter 직접 파이프라인**입니다. `AVMutableComposition` + `AVVideoCompositionCoreAnimationTool` 조합은 iOS/macOS 26에서 deprecated인 데다 CLI 환경에서 동작하지 않아(-11800/-12780), 전 플랫폼에서 검증 가능한 인프로세스 방식을 채택했습니다. 회전(90°)·미러(전면 카메라) 클립 복원은 `tools/preview.swift`의 회전/미러 저장 케이스로 검증돼 있습니다.
- **전면 카메라 산출물은 미리보기(셀피)와 동일하게 미러링**되어 저장됩니다.
- 렌더링 코어(`ios/GrowingCut/Rendering/`)는 UIKit 의존이 없어 macOS 도구와 iOS 앱이 같은 코드를 컴파일합니다.
- 업로드는 `PUT /api/s/:id/photo|video` 두 번이 전부라 실패 시 같은 ID로 재시도해도 QR(이미지에 이미 박힌 링크)이 그대로 유효합니다.
- `Info.plist`의 `NSAllowsArbitraryLoads`는 LAN http 데모용입니다. 실서비스 배포 시 https 서버로 바꾸고 예외를 좁히세요.
