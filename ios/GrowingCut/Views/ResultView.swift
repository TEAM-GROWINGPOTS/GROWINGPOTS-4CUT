import SwiftUI
import CoreGraphics

// MARK: - 합성/업로드 파이프라인

@MainActor
final class ResultEngine: ObservableObject {
    enum Phase: Equatable {
        case renderingStill
        case composingVideo
        case uploading
        case done
        case failed(String)
    }

    @Published var phase: Phase = .renderingStill
    @Published var still: CGImage?
    @Published var qrImage: CGImage?
    @Published var expiresAt: Date?

    private(set) var shareURLString = ""
    private(set) var photoData: Data?
    private(set) var videoURL: URL?

    let sessionID: String = {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }()

    private var started = false

    func runIfNeeded(picked: [Shot], style: FrameStyle, baseURL: String, uploadKey: String, workDir: URL) async {
        guard !started else { return }
        started = true
        await run(picked: picked, style: style, baseURL: baseURL, uploadKey: uploadKey, workDir: workDir)
    }

    func retry(picked: [Shot], style: FrameStyle, baseURL: String, uploadKey: String, workDir: URL) async {
        await run(picked: picked, style: style, baseURL: baseURL, uploadKey: uploadKey, workDir: workDir)
    }

    /// 각 단계 산출물이 이미 있으면 건너뛰므로, 실패 후 재시도 시 실패 지점부터 이어간다.
    private func run(picked: [Shot], style: FrameStyle, baseURL: String, uploadKey: String, workDir: URL) async {
        do {
            shareURLString = "\(baseURL)/s/\(sessionID)"

            // 프레임 오버레이 PNG (스틸·영상 합성이 공유)
            guard let overlay = OverlayLoader.overlay(for: style) else {
                throw resultError("프레임 이미지(\(style.overlayAssetName))를 불러오지 못했어요")
            }
            guard let qr = QRCode.generate(shareURLString, targetSize: 480) else {
                throw resultError("QR 생성에 실패했어요")
            }
            if qrImage == nil {
                qrImage = QRCode.generate(shareURLString, targetSize: 720)
            }

            // 1) 스틸 합성 (QR 포함)
            if photoData == nil {
                phase = .renderingStill
                print("[GC] 스틸 합성 시작")
                let photos = picked.map { Optional($0.photo) }
                let rendered = await Task.detached(priority: .userInitiated) {
                    FrameRenderer.renderStill(photos: photos, overlay: overlay, qr: qr, scale: 1.0)
                }.value
                guard let rendered, let jpeg = ImageEncoder.jpegData(rendered, quality: 0.9) else {
                    throw resultError("네컷 사진 합성에 실패했어요")
                }
                still = rendered
                photoData = jpeg
                print("[GC] 스틸 합성 완료 (\(jpeg.count / 1024)KB)")
            }

            // 2) 움직이는 네컷 합성
            if videoURL == nil {
                phase = .composingVideo
                let videoOverlay = await Task.detached(priority: .userInitiated) {
                    FrameRenderer.renderVideoOverlay(overlay: overlay, qr: qr, scale: 0.5)
                }.value
                guard let videoOverlay else {
                    throw resultError("프레임 합성에 실패했어요")
                }
                let output = workDir.appendingPathComponent("fourcut.mp4")
                try await VideoComposer.compose(
                    clipURLs: picked.map(\.clipURL),
                    overlay: videoOverlay,
                    scale: 0.5,
                    output: output
                )
                videoURL = output
            }

            // 3) 업로드
            phase = .uploading
            print("[GC] 업로드 시작 → \(baseURL)")
            let client = try UploadClient(baseURL: baseURL, uploadKey: uploadKey)
            var expiry: Date?
            if let photoData {
                expiry = try await client.putPhoto(photoData, id: sessionID)
            }
            if let videoURL {
                let videoExpiry = try await client.putVideo(videoURL, id: sessionID)
                expiry = expiry ?? videoExpiry
            }
            expiresAt = expiry ?? Date().addingTimeInterval(4 * 3600)
            phase = .done
            print("[GC] 완료")
        } catch {
            print("[GC] 실패: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }
}

private func resultError(_ message: String) -> NSError {
    NSError(domain: "growingcut.result", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - 결과 화면 (생성 중 → 대기 → 완료, Figma 834×1194 아트보드 1:1)

struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var engine = ResultEngine()

    // 대기 화면 프로모 QR — 화면 진입 시 한 번만 생성
    @State private var instagramQR: CGImage?
    @State private var landingQR: CGImage?

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            ScaledStage {
                switch engine.phase {
                case .renderingStill, .composingVideo:
                    generatingScreen
                case .uploading:
                    waitingScreen
                case .done:
                    completeScreen
                case .failed(let message):
                    failedScreen(message)
                }
            }
            .ignoresSafeArea() // Figma 아트보드(834×1194)는 상태바 포함 전체 화면 기준
        }
        .task {
            let instagram = model.instagramURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if instagramQR == nil, !instagram.isEmpty {
                instagramQR = QRCode.generate(instagram, targetSize: 480)
            }
            let landing = model.landingURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if landingQR == nil, !landing.isEmpty {
                landingQR = QRCode.generate(landing, targetSize: 480)
            }
            await engine.runIfNeeded(
                picked: model.picked,
                style: model.style,
                baseURL: model.normalizedBaseURL,
                uploadKey: model.uploadKey,
                workDir: model.sessionDir
            )
        }
    }

    /// 완료 화면만 라임, 나머지는 다크 (스테이지 밖 풀블리드 배경)
    private var backgroundColor: Color {
        if case .done = engine.phase { return Theme.lime400 }
        return Theme.gray800
    }

    /// iOS 기본 스피너를 lime-500 틴트 + 약 83×84pt로 확대.
    /// Figma 레이어는 스크린샷 캡처 목업("이거 컬러 lime500으로 가능한가요?!?") — 네이티브로 구현.
    private var limeSpinner: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(Theme.lime500)
            .scaleEffect(4.2) // 기본(≈20pt) → 약 84pt
            .frame(width: 83.36, height: 84.48)
    }

    // MARK: - 생성 중 화면 (Figma 5840:22360)

    private var generatingScreen: some View {
        ZStack {
            // 프레임 미리보기 카드 (235.854, 165.563, 362.292×644.074)
            // 스틸이 나오기 전에는 플레이스홀더 카드, 나온 뒤에는 실제 합성본
            Group {
                if let still = engine.still {
                    Image(cg: still)
                        .resizable()
                        .frame(width: 362.292, height: 644.074)
                } else {
                    FramePreviewCard(photos: model.picked.map(\.photo), qr: engine.qrImage)
                        .scaleEffect(362.292 / FramePreviewCard.size.width)
                }
            }
            .position(x: 417.0, y: 487.6)

            Text("사진을 생성 중이에요")
                .font(.pretendard(36, .semiBold))
                .foregroundStyle(.white)
                .placed(x: 268, y: 880.637, w: 298, h: 36)

            limeSpinner
                .position(x: 417.0, y: 1042.88) // (375.321, 1000.637, 83.358×84.480)
        }
    }

    // MARK: - 생성 대기 화면 (Figma 5840:22363)

    private var waitingScreen: some View {
        ZStack {
            // 높이 고정 시 Pretendard 라인박스 때문에 말줄임 위험 — 폭만 고정
            Text("기다리는 동안\nGrowing Pots와 함께 해요!")
                .font(.pretendard(36, .semiBold))
                .lineSpacing(18) // line-height 1.5 = 54pt
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(width: 406)
                .position(x: 417, y: 192.74)

            // 아웃라인 로고 (114, 408.74, 606×144)
            Image.bundled("waiting-logo")
                .resizable()
                .placed(x: 114, y: 408.74, w: 606, h: 144)

            // QR 카드 행 — URL이 비어 있는 카드는 숨김
            HStack(spacing: 20) {
                if let instagramQR {
                    promoQRCard(qr: instagramQR, label: "Instagram")
                }
                if let landingQR {
                    promoQRCard(qr: landingQR, label: "Landing Page")
                }
            }
            .position(x: 417.0, y: 762.63) // 행 rect (157.58, 606.74, 518.84×311.78)

            limeSpinner
                .position(x: 417.0, y: 1043.76) // (375.32, 1001.52, 83.36×84.48)
        }
    }

    /// 대기 화면 프로모 QR 카드 (249.42×311.78, gray-700, radius 10.393)
    private func promoQRCard(qr: CGImage, label: String) -> some View {
        VStack(spacing: 3) {
            Image(cg: qr)
                .interpolation(.none)
                .resizable()
                .padding(10)
                .frame(width: 218.96, height: 218.96)
                .background(.white, in: RoundedRectangle(cornerRadius: 6.169))

            // 스펙 폰트는 Satoshi Bold — 미번들이라 같은 크기의 Pretendard Bold로 대체
            Text(label)
                .font(.pretendard(33.929, .bold))
                .kerning(-0.6786)
                .foregroundStyle(.white)
                .frame(width: 225, height: 51)
        }
        .padding(.top, 12)
        .frame(width: 249.42, height: 311.78, alignment: .top)
        .background(Theme.gray700, in: RoundedRectangle(cornerRadius: 10.393))
    }

    // MARK: - 완료 화면 (Figma 5907:29207)

    private var completeScreen: some View {
        ZStack {
            // 아트보드 밖으로 넘치는 장식만 클리핑 (Figma 클리핑 재현)
            ZStack {
                // 우하단 대형 네컷 스트립 실루엣 (bbox 364.37, 797.47, 630.12×690.89, −5.8°)
                Image.bundled("complete-union-photostrip")
                    .rotationEffect(.degrees(-5.8))
                    .position(x: 679.43, y: 1142.92)

                // 배경 콘페티 (−57.69, 250.61, 891.69×691.72)
                Image.bundled("complete-confetti-bg")
                    .position(x: 388.16, y: 596.47)
            }
            .frame(width: 834, height: 1194)
            .clipped()

            // 상단 화이트 그라디언트 워시 — Figma 실렌더 보정(0.74 @0 → 0 @0.87, 홈 화면과 동일).
            // 레터박스 gap 라인이 안 보이게 상·좌·우 블리드.
            LinearGradient(
                stops: [
                    // 사용자 요청으로 최대 강도 0.74 → 0.60 (홈 화면과 동일)
                    .init(color: .white.opacity(0.60), location: 0),
                    .init(color: .white.opacity(0), location: 0.87),
                ],
                startPoint: UnitPoint(x: 0.0448, y: -0.0328),
                endPoint: UnitPoint(x: 0.9552, y: 1.0328)
            )
            // 대각선 그라데이션의 rect 하단 잘림('흰 박스' 모서리) 방지 — 하단 페이드
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.82),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .placed(x: -40.49, y: -19.52, w: 914.49, h: 942.18)
            .allowsHitTesting(false)

            // 체크 배지 (bbox 668.89, 295.46, 88.32×86.85, 28.86°)
            Image.bundled("complete-check")
                .rotationEffect(.degrees(28.86))
                .position(x: 713.05, y: 338.89)

            // 느낌표 배지(대) (bbox 87.62, 562.80, 113.31×109.98, −17.84°)
            Image.bundled("complete-exclamation-large")
                .rotationEffect(.degrees(-17.84))
                .position(x: 144.28, y: 617.79)

            // 완성 네컷 카드 (274.86, 178.12, 284.28×505.38)
            // 카드 내부 장식(콘페티·학사모·로고·미니 QR)은 합성 스틸에 이미 포함 — 실제 이미지로 대체
            Group {
                if let still = engine.still {
                    Image(cg: still).resizable()
                } else {
                    Theme.lime500
                }
            }
            .placed(x: 274.86, y: 178.12, w: 284.28, h: 505.38)

            // 높이는 고정하지 않는다 — Pretendard 고유 라인박스(>24pt) 때문에 108pt 고정 시 말줄임 발생
            Text("감사합니다!\n자 이제 QR을 통해 \n이미지를 다운로드하세요!")
                .font(.pretendard(24, .semiBold))
                .lineSpacing(12) // line-height 1.5 = 36pt
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.gray800)
                .frame(width: 413.83)
                .position(x: 417, y: 783.5)

            // 다운로드 QR 카드 (333.75, 910.50, 166.51×166.51)
            downloadQRCard
                .placed(x: 333.75, y: 910.50, w: 166.51, h: 166.51)

            // 홈으로 가기 (50, 55.74, 147×58)
            Button {
                model.backToMain()
            } label: {
                Text("홈으로 가기").kerning(-0.2)
            }
            .buttonStyle(PrimaryButtonStyle(fontSize: 20, horizontalPadding: 28, verticalPadding: 16))
            .position(x: 123.5, y: 84.74)
        }
        // 클리핑은 장식 그룹에만 적용 — 흰 그라데이션은 레터박스까지 블리드되어야 함
    }

    /// 완료 화면 대형 QR 카드 (흰 배경, 3pt gray-800 테두리, radius 6.902)
    private var downloadQRCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6.902)
                .fill(.white)
            RoundedRectangle(cornerRadius: 6.902)
                .strokeBorder(Theme.gray800, lineWidth: 3)
            if let qrImage = engine.qrImage {
                Image(cg: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .padding(12)
            }
        }
    }

    // MARK: - 실패 화면 (재시도)

    private func failedScreen(_ message: String) -> some View {
        VStack(spacing: 0) {
            Text("문제가 생겼어요")
                .font(.pretendard(36, .semiBold))
                .foregroundStyle(.white)

            Text(message)
                .font(.pretendard(20, .regular))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.top, 28)
                .padding(.horizontal, 140)

            HStack(spacing: 20) {
                Button {
                    Task {
                        await engine.retry(
                            picked: model.picked,
                            style: model.style,
                            baseURL: model.normalizedBaseURL,
                            uploadKey: model.uploadKey,
                            workDir: model.sessionDir
                        )
                    }
                } label: {
                    Text("다시 시도")
                        .font(.pretendard(24, .semiBold))
                        .foregroundStyle(Theme.gray900)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 24)
                        .background(Theme.lime500, in: Capsule())
                }
                .buttonStyle(.plain)

                Button("홈으로 가기") { model.backToMain() }
                    .buttonStyle(GhostButtonStyle(fontSize: 24))
            }
            .padding(.top, 64)
        }
    }
}

// MARK: - 프레임 미리보기 카드 (생성 중 플레이스홀더)

/// 라임 프레임의 축소 미리보기. 완료 화면 카드 좌표계(284.28×505.38)로 그리고,
/// 생성 중 화면에서는 362.292/284.28배로 확대해 쓴다 (두 화면의 카드는 동일 디자인·비율).
/// 장식은 complete-* 번들 에셋 재사용 — 같은 일러스트를 카드 배율만 달리한 것.
private struct FramePreviewCard: View {
    let photos: [CGImage]
    let qr: CGImage?

    static let size = CGSize(width: 284.28, height: 505.38)

    private static let cellSize = CGSize(width: 126.345, height: 177.804)
    private static let cellOrigins = [
        CGPoint(x: 11.58, y: 70.67),
        CGPoint(x: 146.35, y: 70.67),
        CGPoint(x: 11.58, y: 256.90),
        CGPoint(x: 146.35, y: 256.90),
    ]

    var body: some View {
        ZStack {
            Theme.lime500

            // 카드 내부 콘페티 (rel −61.40, 0, 405.54×626.76 — 카드에 클리핑)
            Image.bundled("complete-confetti-frame")
                .position(x: 141.37, y: 313.38)

            // 2×2 사진 그리드
            ForEach(0..<4, id: \.self) { i in
                Group {
                    if i < photos.count {
                        Image(cg: photos[i])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.white
                    }
                }
                .frame(width: Self.cellSize.width, height: Self.cellSize.height)
                .clipped()
                .position(
                    x: Self.cellOrigins[i].x + Self.cellSize.width / 2,
                    y: Self.cellOrigins[i].y + Self.cellSize.height / 2
                )
            }

            // 좌상단 학사모
            Image.bundled("complete-hat3")
                .position(x: 32.98, y: 41.67)

            // 미니 QR 박스 (rel 227.11, 16.59, 41.26×41.26)
            RoundedRectangle(cornerRadius: 1.71)
                .fill(.white)
                .overlay {
                    if let qr {
                        Image(cg: qr)
                            .interpolation(.none)
                            .resizable()
                            .padding(3)
                    } else {
                        Text("QR 자리")
                            .font(.pretendard(6.841, .semiBold))
                            .kerning(-0.0684)
                            .foregroundStyle(.black)
                    }
                }
                .placed(x: 227.11, y: 16.59, w: 41.26, h: 41.26)

            // 우하단 학사모 (11.82°)
            Image.bundled("complete-hat1")
                .rotationEffect(.degrees(11.82))
                .position(x: 237.29, y: 464.01)

            // 느낌표 배지(소) — 중첩 회전 6.53° + −17.84°의 합성 근사
            Image.bundled("complete-exclamation-small")
                .rotationEffect(.degrees(-11.31))
                .position(x: 45.59, y: 436.22)

            // 스파클 획 우하 (14.96°)
            Image.bundled("complete-sparkle-stroke-br")
                .rotationEffect(.degrees(14.96))
                .position(x: 191.08, y: 474.22)

            // 스파클 획 상단 (−170.8° + 상하반전)
            Image.bundled("complete-sparkle-stroke-tl")
                .scaleEffect(x: 1, y: -1)
                .rotationEffect(.degrees(-170.8))
                .position(x: 112.97, y: 28.47)

            // growing pots 로고
            Image.bundled("complete-logo1")
                .position(x: 144.58, y: 451.74)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }
}

// MARK: - 배치 헬퍼

private extension View {
    /// Figma 절대좌표 rect를 그대로 옮긴다 — 부모 좌표계 기준 (x, y, w, h)
    func placed(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
    }
}
