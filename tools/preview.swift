import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// macOS에서 렌더링/영상 합성 코어를 검증하는 도구.
/// 사용: preview <출력 디렉터리>
@main
struct PreviewTool {
    static func main() async {
        do {
            try await run()
            print("PREVIEW OK")
        } catch {
            print("PREVIEW FAILED: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./preview-out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let url = "http://192.168.0.10:8787/s/abc123xyz0"
        guard let qr = QRCode.generate(url) else { throw ToolError("QR 생성 실패") }
        let photos: [CGImage?] = (0..<4).map { DemoMedia.makePhoto(index: $0) }
        guard photos.allSatisfy({ $0 != nil }) else { throw ToolError("데모 사진 생성 실패") }
        let dateText = "2026.07.12 15:30"

        // 1) 스틸 렌더: 여러 스타일 미리보기(축소) + 풀스케일 1장
        for style in FrameStyle.all {
            guard let still = FrameRenderer.renderStill(photos: photos, style: style, qr: qr, dateText: dateText, scale: 0.3) else {
                throw ToolError("스틸 렌더 실패: \(style.id)")
            }
            try writePNG(still, to: outDir.appendingPathComponent("still-\(style.id).png"))
        }
        guard let fullStill = FrameRenderer.renderStill(photos: photos, style: .byID("white"), qr: qr, dateText: dateText, scale: 1.0) else {
            throw ToolError("풀스케일 스틸 렌더 실패")
        }
        try writePNG(fullStill, to: outDir.appendingPathComponent("still-full.png"))

        // QR 디코드 검증
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: fullStill)) ?? []
        let decoded = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        if decoded.contains(url) {
            print("QR DECODE OK: \(url)")
        } else {
            print("QR DECODE FAILED: \(decoded)")
        }

        // 선택 미리보기(사진 2장만 + QR 없음) 렌더도 확인
        if let partial = FrameRenderer.renderStill(photos: [photos[0], nil, photos[2], nil], style: .byID("pink"), qr: nil, dateText: dateText, scale: 0.3) {
            try writePNG(partial, to: outDir.appendingPathComponent("still-partial.png"))
        }

        // 2) 영상 합성: 4:3 데모 클립 4개 → 움직이는 네컷
        //    clip1은 90° 회전 저장, clip2는 미러 저장으로 preferredTransform 복원 경로를 검증한다.
        //    기대 결과: 모든 셀 정립(마커 삼각형 좌상단), 단 3번째 셀(clip2)만 좌우 반전(삼각형 우상단).
        let clipDir = outDir.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
        var clips: [URL] = []
        let orientations: [DemoMedia.StoredOrientation] = [.normal, .rotated90, .mirrored, .normal]
        for i in 0..<4 {
            let clipURL = clipDir.appendingPathComponent("clip\(i).mp4")
            try await DemoMedia.makeClip(index: i, duration: 3.0, orientation: orientations[i], to: clipURL)
            clips.append(clipURL)
        }
        print("CLIPS OK")

        let style = FrameStyle.byID("film")
        guard let overlay = FrameRenderer.renderVideoOverlay(style: style, qr: qr, dateText: dateText, scale: 0.5) else {
            throw ToolError("오버레이 렌더 실패")
        }
        try writePNG(overlay, to: outDir.appendingPathComponent("overlay.png"))

        let movieURL = outDir.appendingPathComponent("fourcut.mp4")
        try await VideoComposer.compose(clipURLs: clips, overlay: overlay, scale: 0.5, output: movieURL)

        // 3) 결과 영상 프레임 추출 + 길이 확인
        let asset = AVURLAsset(url: movieURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await tracks.first?.load(.naturalSize) ?? .zero
        print(String(format: "MOVIE OK duration=%.2fs size=%.0fx%.0f", duration, size.width, size.height))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (i, t) in [0.2, 1.5, 2.7].enumerated() {
            let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            try writePNG(image, to: outDir.appendingPathComponent("movie-frame\(i).png"))
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError("PNG 생성 실패: \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ToolError("PNG 저장 실패: \(url.lastPathComponent)")
        }
    }
}

struct ToolError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}
