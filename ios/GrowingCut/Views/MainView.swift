import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()

            ScaledStage {
                VStack(spacing: 0) {
                    Spacer()

                    Text("GROWING CUT")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .kerning(10)
                        .foregroundStyle(Theme.pink)

                    Text("네컷사진")
                        .font(.system(size: 88, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 6)

                    Text("5초에 한 번, 여덟 번의 찰칵 —\n마음에 드는 네 컷을 골라보세요")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)

                    Button {
                        model.startCapture()
                    } label: {
                        Label("촬영 시작", systemImage: "camera.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 30))
                    .padding(.top, 48)

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
                    .buttonStyle(GhostButtonStyle())
                    .disabled(model.demoBuilding)
                    .padding(.top, 18)
                    #endif

                    Spacer()

                    VStack(spacing: 12) {
                        footStep(icon: "camera.fill", text: "5초 타이머로 8컷 자동 촬영")
                        footStep(icon: "checkmark.rectangle.stack.fill", text: "4컷 + 프레임 선택 (2×2)")
                        footStep(icon: "qrcode", text: "QR로 사진·영상 저장 (4시간)")
                    }
                    .padding(.bottom, 40)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.ink.opacity(0.35))
                            .padding(14)
                            .background(.white.opacity(0.6), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(20)
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

    private func footStep(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.pink)
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.6))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.white.opacity(0.65), in: Capsule())
    }
}
