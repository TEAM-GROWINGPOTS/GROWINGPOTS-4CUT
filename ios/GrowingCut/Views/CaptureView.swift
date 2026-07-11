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
    @State private var skipRequested = false
    @State private var elapsedInShot = 0.0
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

            // 진행 상황 + 컨트롤
            VStack {
                HStack(alignment: .top) {
                    Button {
                        showCancelConfirm = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    Spacer()
                    progressDots
                    Spacer()
                    Color.clear.frame(width: 48, height: 48)
                }
                .padding(24)

                Spacer()

                if countdown > 0 {
                    Text("\(countdown)")
                        .font(.system(size: 170, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 4)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: countdown)
                }

                Spacer()

                if camera.status == .ready {
                    VStack(spacing: 12) {
                        Text("\(min(shotIndex + 1, model.shotCount)) / \(model.shotCount) 컷")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text("타이머가 끝나면 자동으로 찍혀요 — 5초 동안 영상도 함께 담겨요 🎬")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                        Button("바로 찍기 📸") {
                            skipRequested = true
                        }
                        .buttonStyle(GhostButtonStyle(fontSize: 17))
                        .tint(.white)
                        .opacity(countdown > 0 && elapsedInShot >= 2 ? 1 : 0)
                    }
                    .padding(.bottom, 28)
                }
            }

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
                        Text("찰칵! ✨ \(shots.count) / \(model.shotCount)")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
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

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(0..<model.shotCount, id: \.self) { i in
                Circle()
                    .fill(i < shots.count ? Theme.pink : .white.opacity(i == shots.count ? 0.95 : 0.35))
                    .frame(width: 13, height: 13)
                    .scaleEffect(i == shots.count ? 1.25 : 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.35), in: Capsule())
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
                message: "설정 앱 → 개인정보 보호 → 카메라에서\nGROWING CUT을 허용해 주세요."
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
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("처음으로") { model.backToMain() }
                .buttonStyle(PrimaryButtonStyle(fontSize: 20))
                .padding(.top, 8)
        }
        .padding(40)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 28))
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

                // 10초 카운트다운 (0.1초 틱, '바로 찍기' 반영)
                skipRequested = false
                elapsedInShot = 0
                var remaining = Double(model.countdownSeconds)
                countdown = model.countdownSeconds
                while remaining > 0 && !skipRequested {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    remaining -= 0.1
                    elapsedInShot += 0.1
                    countdown = max(1, Int(remaining.rounded(.up)))
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
