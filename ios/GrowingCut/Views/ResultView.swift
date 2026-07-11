import SwiftUI
import CoreGraphics
import Photos

// MARK: - 합성/업로드 파이프라인

@MainActor
final class ResultEngine: ObservableObject {
    enum Phase: Equatable {
        case renderingStill
        case composingVideo
        case uploading
        case done
        case failed(String)

        var label: String {
            switch self {
            case .renderingStill: return "네컷 사진 만드는 중… 🖼️"
            case .composingVideo: return "움직이는 네컷 만드는 중… 🎬"
            case .uploading: return "업로드하는 중… ☁️"
            case .done: return "완성!"
            case .failed: return "문제가 생겼어요"
            }
        }
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

    func runIfNeeded(picked: [Shot], style: FrameStyle, baseURL: String, workDir: URL) async {
        guard !started else { return }
        started = true
        await run(picked: picked, style: style, baseURL: baseURL, workDir: workDir)
    }

    func retry(picked: [Shot], style: FrameStyle, baseURL: String, workDir: URL) async {
        await run(picked: picked, style: style, baseURL: baseURL, workDir: workDir)
    }

    /// 각 단계 산출물이 이미 있으면 건너뛰므로, 실패 후 재시도 시 실패 지점부터 이어간다.
    private func run(picked: [Shot], style: FrameStyle, baseURL: String, workDir: URL) async {
        do {
            shareURLString = "\(baseURL)/s/\(sessionID)"
            let dateText = Self.dateFormatter.string(from: Date())

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
                    FrameRenderer.renderStill(photos: photos, style: style, qr: qr, dateText: dateText, scale: 1.0)
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
                let overlay = await Task.detached(priority: .userInitiated) {
                    FrameRenderer.renderVideoOverlay(style: style, qr: qr, dateText: dateText, scale: 0.5)
                }.value
                guard let overlay else {
                    throw resultError("프레임 합성에 실패했어요")
                }
                let output = workDir.appendingPathComponent("fourcut.mp4")
                try await VideoComposer.compose(
                    clipURLs: picked.map(\.clipURL),
                    overlay: overlay,
                    scale: 0.5,
                    output: output
                )
                videoURL = output
            }

            // 3) 업로드
            phase = .uploading
            print("[GC] 업로드 시작 → \(baseURL)")
            let client = try UploadClient(baseURL: baseURL)
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

    func saveToPhotos() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        let photoData = photoData
        let videoURL = videoURL
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if let photoData {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photoData, options: nil)
                }
                if let videoURL {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: videoURL, options: nil)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd HH:mm"
        return f
    }()
}

private func resultError(_ message: String) -> NSError {
    NSError(domain: "growingcut.result", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - 결과 화면 (세로: 위 네컷 이미지, 아래 QR 패널)

struct ResultView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var engine = ResultEngine()
    @State private var saveState: SaveState = .idle

    enum SaveState: Equatable { case idle, saving, saved, failed }

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()

            ScaledStage {
                VStack(spacing: 24) {
                    stripPane
                    sidePanel
                        .frame(height: 320)
                }
                .padding(32)
            }

            if saveState == .saved || saveState == .failed {
                VStack {
                    Spacer()
                    Text(saveState == .saved ? "사진 앱에 저장했어요 ✅" : "저장하지 못했어요 — 사진 접근 권한을 확인해 주세요")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, 30)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: saveState)
        .task {
            await engine.runIfNeeded(
                picked: model.picked,
                style: model.style,
                baseURL: model.normalizedBaseURL,
                workDir: model.sessionDir
            )
        }
    }

    // MARK: - Pieces

    private var stripPane: some View {
        Group {
            if let still = engine.still {
                Image(cg: still)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.5))
                    .aspectRatio(LayoutSpec.standard.size.width / LayoutSpec.standard.size.height, contentMode: .fit)
                    .overlay { ProgressView().controlSize(.large) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sidePanel: some View {
        switch engine.phase {
        case .renderingStill, .composingVideo, .uploading:
            processingPanel
        case .done:
            donePanel
        case .failed(let message):
            failedPanel(message)
        }
    }

    private var processingPanel: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.pink)
            Text(engine.phase.label)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.ink)
            Text("잠시만 기다려 주세요")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 26))
    }

    private var donePanel: some View {
        HStack(spacing: 26) {
            if let qrImage = engine.qrImage {
                Image(cg: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 208, height: 208)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("완성! 🎉")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.ink)

                Text("휴대폰 카메라로 QR을 찍으면 사진과\n움직이는 네컷을 저장할 수 있어요")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                if let expiresAt = engine.expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remain = max(0, expiresAt.timeIntervalSince(context.date))
                        Label(remainText(remain), systemImage: "clock.fill")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(remain > 0 ? Theme.pink : .red)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.pinkSoft.opacity(0.6), in: Capsule())
                }

                Text(engine.shareURLString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                HStack(spacing: 12) {
                    Button {
                        guard saveState != .saving else { return }
                        saveState = .saving
                        Task {
                            let ok = await engine.saveToPhotos()
                            saveState = ok ? .saved : .failed
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            saveState = .idle
                        }
                    } label: {
                        Label("이 기기에 저장", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(GhostButtonStyle(fontSize: 17))

                    Button {
                        model.backToMain()
                    } label: {
                        Label("처음으로", systemImage: "house.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 19))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 26))
    }

    private func failedPanel(_ message: String) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.pink)
                Text("앗, 문제가 생겼어요")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.ink)
            }
            Text(message)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button {
                    Task {
                        await engine.retry(
                            picked: model.picked,
                            style: model.style,
                            baseURL: model.normalizedBaseURL,
                            workDir: model.sessionDir
                        )
                    }
                } label: {
                    Label("다시 시도", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle(fontSize: 19))

                Button("처음으로") { model.backToMain() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 26))
    }

    private func remainText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d 남음", total / 3600, total % 3600 / 60, total % 60)
    }
}
