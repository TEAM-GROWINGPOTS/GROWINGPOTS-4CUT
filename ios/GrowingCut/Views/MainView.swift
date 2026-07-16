import SwiftUI

/// 홈 화면 — Figma 5840:22157 "iPad Pro 11\" - 1" (834×1194) 1:1 재현
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false
    @State private var buttonFloating = false

    var body: some View {
        ZStack {
            // 스테이지 밖 레터박스도 아트보드와 같은 라임 배경
            Theme.lime400.ignoresSafeArea()

            ScaledStage {
                ZStack {
                    Theme.lime400

                    // Union — 우하단 새싹 실루엣: 컨테이너 (364.37, 854.95, 630.12×690.89) 중앙, -5.8° 회전
                    Image.bundled("home-union-frame")
                        .resizable()
                        .frame(width: 568.691, height: 636.675)
                        .rotationEffect(.degrees(-5.8))
                        .position(x: 679.43, y: 1200.4)

                    // Group 462 — 콘페티: rect (-57.69, 250.61, 891.69×691.72)
                    Image.bundled("home-confetti-group462")
                        .resizable()
                        .frame(width: 891.691, height: 691.718)
                        .position(x: 388.16, y: 596.47)

                    // Rectangle 287 — 흰색 그라데이션 오버레이: rect (0, 0, 834×902)
                    whiteOverlay
                        .frame(width: 834, height: 902)
                        .position(x: 417, y: 451)

                    // 카피 2줄: rect (214.5, 245.07, 405×90), Bold 32 / line-height 1.4 / -0.32
                    Text("감사한 사람들과 함께하는 졸업식\n자 이제 사진 찍자!")
                        .font(.pretendard(32, .bold))
                        .kerning(-0.32)
                        .lineSpacing(12.8)          // 44.8pt 행높이 − 32pt 폰트
                        .padding(.vertical, 6.4)    // 행높이 여백(하프 리딩) 보정
                        .foregroundStyle(Theme.gray600)
                        .multilineTextAlignment(.center)
                        .frame(width: 405)
                        .position(x: 417, y: 290.07)

                    // img_logo1 — growing pots 로고: rect (217.12, 406.07, 399.76×226.41)
                    Image.bundled("home-logo1")
                        .resizable()
                        .frame(width: 399.762, height: 226.406)
                        .position(x: 417, y: 519.27)

                    // 촬영 시작 버튼: rect (291, 827.47, 252×104) + 둥실둥실 애니메이션(디자이너 주석)
                    Button {
                        model.startCapture()
                    } label: {
                        Text("촬영 시작")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .offset(y: buttonFloating ? -6 : 6)
                    .position(x: 417, y: 879.47)

                    #if targetEnvironment(simulator)
                    Button {
                        model.startDemoCapture()
                    } label: {
                        if model.demoBuilding {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("데모 컷 만드는 중…")
                            }
                        } else {
                            Text("🎨 데모 촬영 (시뮬레이터용)")
                        }
                    }
                    .buttonStyle(GhostButtonStyle(fontSize: 16))
                    .disabled(model.demoBuilding)
                    .position(x: 417, y: 1005)
                    #endif

                    // img_check — 체크 스티커: 컨테이너 (668.89, 295.46, 88.32×86.85) 중앙, +28.86° 회전
                    Image.bundled("home-check")
                        .resizable()
                        .frame(width: 66.337, height: 62.609)
                        .rotationEffect(.degrees(28.86))
                        .position(x: 713.05, y: 338.89)

                    // img_exclamation — 느낌표 스티커: 컨테이너 (118.04, 619.81, 113.31×109.98) 중앙, -17.84° 회전
                    Image.bundled("home-exclamation")
                        .resizable()
                        .frame(width: 91.312, height: 86.146)
                        .rotationEffect(.degrees(-17.84))
                        .position(x: 174.7, y: 674.8)
                }
                .frame(width: 834, height: 1194)
                .clipped() // 아트보드 밖으로 나간 새싹/콘페티를 Figma처럼 잘라낸다
            }

            // 설정 (기능 유지, 디자인을 방해하지 않게 은은하게)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.ink.opacity(0.3))
                            .padding(14)
                            .contentShape(Circle())
                    }
                }
                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                buttonFloating = true
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .alert("데모 촬영 실패", isPresented: .init(
            get: { model.demoError != nil },
            set: { if !$0 { model.demoError = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.demoError ?? "")
        }
    }

    /// CSS `linear-gradient(141.676deg, rgba(255,255,255,0.74) 44.519%, rgba(255,255,255,0) 78.458%)` 재현.
    /// CSS 각도(0°=위, 시계방향) → 방향벡터 d = (sin141.676°, -cos141.676°) = (0.6201, 0.7845).
    /// 그라데이션 라인 길이 L = 834·dx + 902·dy ≈ 1224.8 → 중심(417, 451)에서 ±L/2 지점을
    /// 834×902 프레임의 UnitPoint로 환산: start(0.0447, -0.0326), end(0.9553, 1.0326). stop %는 CSS 그대로.
    private var whiteOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.74), location: 0.44519),
                .init(color: .white.opacity(0), location: 0.78458),
            ],
            startPoint: UnitPoint(x: 0.0447, y: -0.0326),
            endPoint: UnitPoint(x: 0.9553, y: 1.0326)
        )
    }
}
