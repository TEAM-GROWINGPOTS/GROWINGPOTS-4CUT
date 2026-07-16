import SwiftUI
import AVFoundation

struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var camera = CameraService()

    @State private var shotIndex = 0
    @State private var countdown = 0
    @State private var shots: [Shot] = []
    @State private var flashOpacity = 0.0
    @State private var interstitial: CGImage?
    @State private var guideRect = CGRect.null
    @State private var errorMessage: String?
    @State private var showCancelConfirm = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(camera: camera, guideRect: $guideRect)
                .ignoresSafeArea()

            // 저장 영역 가이드
            if camera.status == .ready, !guideRect.isNull {
                Rectangle()
                    .path(in: guideRect)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                    .foregroundStyle(.white.opacity(0.4))
                    .ignoresSafeArea()
            }

            statusOverlay

            // UI 크롬 — Figma 아트보드(834×1194) 좌표 1:1 (노드 5840:22354)
            ScaledStage {
                ZStack {
                    // 뒤로 가기 캡슐 — rect (50, 56, 130, 58), #242424 60%
                    Button {
                        showCancelConfirm = true
                    } label: {
                        Text("뒤로 가기")
                            .font(.pretendard(20, .semiBold))
                            .tracking(-0.2)
                            .foregroundStyle(.white)
                            .frame(width: 130, height: 58)
                            .background(Theme.gray800.opacity(0.6), in: Capsule())
                    }
                    .position(x: 115, y: 85)

                    // 진행 도트 — rect (343, 71, 148, 28), 상단 중앙
                    progressDots
                        .position(x: 417, y: 85)

                    // 대형 카운트다운 — center (417, 587), 180pt
                    if countdown > 0 {
                        Text("\(countdown)")
                            .font(.pretendard(180, .bold))
                            .tracking(-1.8)
                            .foregroundStyle(.white)
                            .largeShadow()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy, value: countdown)
                            .position(x: 417, y: 587)
                    }

                    // 하단 "n/6 컷" 라벨 — center (417, 1079), 32pt
                    if camera.status == .ready {
                        Text("\(min(shotIndex + 1, model.shotCount))/\(model.shotCount) 컷")
                            .font(.pretendard(32, .semiBold))
                            .tracking(-0.32)
                            .foregroundStyle(.white)
                            .largeShadow()
                            .position(x: 417, y: 1079)
                    }
                }
            }
            .ignoresSafeArea()

            // 촬영 플래시
            Color.white
                .ignoresSafeArea()
                .opacity(flashOpacity)
                .allowsHitTesting(false)

            // 찍힌 컷 미리보기
            if let interstitial {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(cg: interstitial)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 380, maxHeight: 440)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(radius: 24)
                        Text("찰칵! \(shots.count)/\(model.shotCount) 컷")
                            .font(.pretendard(32, .semiBold))
                            .tracking(-0.32)
                            .foregroundStyle(.white)
                    }
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: interstitial == nil)
        .task { await run() }
        .onDisappear { camera.stop() }
        .alert("촬영에 문제가 생겼어요", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("처음으로") { model.backToMain() }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("촬영을 그만둘까요?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("촬영 그만두기", role: .destructive) { model.backToMain() }
            Button("계속 찍기", role: .cancel) {}
        }
    }

    // MARK: - Pieces

    /// 진행 도트 6개 — 완료 컷 라임(r6), 현재 컷 확대 gray-50(r8), 대기 컷 흰색 80%(r6).
    /// 알약 배경 검정 4% / radius 14. (시안 SVG는 상태가 한 스텝 어긋나 있어 규칙으로 렌더)
    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<model.shotCount, id: \.self) { i in
                let isCurrent = i == shots.count
                Circle()
                    .fill(i < shots.count
                          ? Theme.lime500
                          : (isCurrent ? Theme.gray50 : .white.opacity(0.8)))
                    .frame(width: isCurrent ? 16 : 12, height: isCurrent ? 16 : 12)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 16)
        .background(.black.opacity(0.04), in: Capsule())
        .animation(.spring(duration: 0.3), value: shots.count)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .unavailable:
            cameraMessage(
                icon: "camera.badge.ellipsis",
                title: "여기서는 카메라를 쓸 수 없어요",
                message: "시뮬레이터에는 카메라가 없어요.\n메인 화면의 '데모 촬영'으로 전체 흐름을 확인해 보세요."
            )
        case .denied:
            cameraMessage(
                icon: "lock.shield",
                title: "카메라 접근이 꺼져 있어요",
                message: "설정 앱 → 개인정보 보호 → 카메라에서\ngrowing pots를 허용해 주세요."
            )
        case .failed(let reason):
            cameraMessage(icon: "exclamationmark.triangle", title: "카메라 오류", message: reason)
        case .idle, .configuring:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .ready:
            EmptyView()
        }
    }

    private func cameraMessage(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.9))
            Text(title)
                .font(.pretendard(28, .semiBold))
                .foregroundStyle(.white)
            Text(message)
                .font(.pretendard(17, .regular))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("처음으로") { model.backToMain() }
                .buttonStyle(PrimaryButtonStyle(fontSize: 20, horizontalPadding: 36, verticalPadding: 18))
                .padding(.top, 8)
        }
        .padding(40)
        .background(Theme.gray900.opacity(0.6), in: RoundedRectangle(cornerRadius: 28))
    }

    // MARK: - 촬영 루프

    private func run() async {
        await camera.configure()
        guard camera.status == .ready else { return }

        do {
            // 세션 안정화 대기
            try await Task.sleep(nanoseconds: 700_000_000)

            for i in 0..<model.shotCount {
                shotIndex = i
                let clipURL = model.sessionDir.appendingPathComponent("clip\(i).mov")
                try await camera.startRecording(to: clipURL)

                // 5초 카운트다운 (녹화는 카운트다운 동안 계속 돈다)
                for remaining in stride(from: model.countdownSeconds, through: 1, by: -1) {
                    countdown = remaining
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                countdown = 0

                // 찰칵: 플래시 → 사진 → 녹화 종료
                withAnimation(.easeIn(duration: 0.08)) { flashOpacity = 0.9 }
                let photo = try await camera.capturePhoto()
                let clip = try await camera.stopRecording()
                withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }

                let shot = Shot(photo: photo, clipURL: clip)
                shots.append(shot)

                if shots.count < model.shotCount {
                    interstitial = photo
                    try await Task.sleep(nanoseconds: 1_300_000_000)
                    interstitial = nil
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            camera.stop()
            model.finishCapture(shots)
        } catch is CancellationError {
            // 화면 이탈 — 조용히 종료
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 텍스트 그림자

private extension View {
    /// Figma Effect "Large" — #131414 8% 2겹: (0,16) blur 24 + (0,6) blur 10.
    /// SwiftUI radius ≈ blur/2 로 환산, spread(-6/-4)는 SwiftUI 미지원이라 생략.
    func largeShadow() -> some View {
        self
            .shadow(color: Color(hex: 0x131414, opacity: 0.08), radius: 12, y: 16)
            .shadow(color: Color(hex: 0x131414, opacity: 0.08), radius: 5, y: 6)
    }
}

// MARK: - 카메라 미리보기

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraService
    @Binding var guideRect: CGRect

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onGuideChange = { rect in
            DispatchQueue.main.async { guideRect = rect }
        }
        camera.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.sourceAspect = camera.sourceAspect
        camera.attachPreview(view.previewLayer)
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var sourceAspect: CGFloat = 0 {
        didSet { if oldValue != sourceAspect { setNeedsLayout() } }
    }
    var onGuideChange: ((CGRect) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        publishGuideRect()
    }

    /// 최종 4컷에 실제로 저장되는 중앙 크롭 영역을 미리보기 좌표로 변환
    private func publishGuideRect() {
        guard sourceAspect > 0, bounds.width > 0, previewLayer.connection != nil else {
            onGuideChange?(.null)
            return
        }
        let cell = LayoutSpec.standard.cellSize
        let target = cell.width / cell.height
        var w: CGFloat = 1
        var h: CGFloat = 1
        if sourceAspect > target {
            w = target / sourceAspect
        } else {
            h = sourceAspect / target
        }
        let normalized = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        onGuideChange?(previewLayer.layerRectConverted(fromMetadataOutputRect: normalized))
    }
}
