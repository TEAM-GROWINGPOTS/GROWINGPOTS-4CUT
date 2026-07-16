import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// macOS에서 렌더링/영상 합성 코어를 검증하는 도구.
/// 사용: preview <출력 디렉터리> [프레임 오버레이 디렉터리]
///   프레임 디렉터리 기본값: ios/GrowingCut/Resources/Frames (CWD 기준)
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
        let framesDir = URL(fileURLWithPath: CommandLine.arguments.count > 2
            ? CommandLine.arguments[2]
            : "ios/GrowingCut/Resources/Frames")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 0) 오버레이 로드 + 투명 슬롯 검증
        let layout = LayoutSpec.standard
        var overlays: [String: CGImage] = [:]
        for style in FrameStyle.all {
            let url = framesDir.appendingPathComponent("\(style.overlayAssetName).png")
            guard let overlay = OverlayLoader.load(url: url) else {
                throw ToolError("오버레이 로드 실패: \(url.path)")
            }
            guard overlay.width == Int(layout.size.width), overlay.height == Int(layout.size.height) else {
                throw ToolError("오버레이 크기 불일치(\(style.id)): \(overlay.width)x\(overlay.height) ≠ \(Int(layout.size.width))x\(Int(layout.size.height))")
            }
            for (i, rect) in layout.cellRects.enumerated() {
                let a = alphaAtLayoutPoint(overlay, CGPoint(x: rect.midX, y: rect.midY), layoutSize: layout.size)
                guard a < 0.02 else {
                    throw ToolError("오버레이 슬롯 불투명(\(style.id) 셀\(i) alpha=\(a)) — Figma 내보내기에 배경이 섞였는지 확인")
                }
            }
            // 프레임 크롬(컬럼 사이 간격 중앙)은 불투명해야 정상
            let chrome = alphaAtLayoutPoint(overlay, CGPoint(x: 540, y: 500), layoutSize: layout.size)
            guard chrome > 0.98 else {
                throw ToolError("오버레이 크롬이 투명함(\(style.id) alpha=\(chrome)) — 잘못된 레이어 내보내기")
            }
            overlays[style.id] = overlay
        }
        print("OVERLAY ALPHA OK (\(overlays.count) styles)")

        let url = "http://192.168.0.10:8787/s/abc123xyz0"
        guard let qr = QRCode.generate(url) else { throw ToolError("QR 생성 실패") }
        let photos: [CGImage?] = (0..<4).map { DemoMedia.makePhoto(index: $0) }
        guard photos.allSatisfy({ $0 != nil }) else { throw ToolError("데모 사진 생성 실패") }

        // 1) 스틸 렌더: 3종 스타일 미리보기(축소) + 풀스케일 1장
        for style in FrameStyle.all {
            guard let overlay = overlays[style.id],
                  let still = FrameRenderer.renderStill(photos: photos, overlay: overlay, qr: qr, scale: 0.3)
            else { throw ToolError("스틸 렌더 실패: \(style.id)") }
            try writePNG(still, to: outDir.appendingPathComponent("still-\(style.id).png"))
        }
        guard let limeOverlay = overlays["lime"],
              let fullStill = FrameRenderer.renderStill(photos: photos, overlay: limeOverlay, qr: qr, scale: 1.0)
        else { throw ToolError("풀스케일 스틸 렌더 실패") }
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
        if let whiteOverlay = overlays["white"],
           let partial = FrameRenderer.renderStill(photos: [photos[0], nil, photos[2], nil], overlay: whiteOverlay, qr: nil, scale: 0.3) {
            try writePNG(partial, to: outDir.appendingPathComponent("still-partial.png"))
        }

        // 2) 영상 합성: 데모 클립 4개 → 움직이는 네컷
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

        guard let videoOverlay = FrameRenderer.renderVideoOverlay(overlay: limeOverlay, qr: qr, scale: 0.5) else {
            throw ToolError("오버레이 렌더 실패")
        }
        try writePNG(videoOverlay, to: outDir.appendingPathComponent("overlay.png"))

        let movieURL = outDir.appendingPathComponent("fourcut.mp4")
        try await VideoComposer.compose(clipURLs: clips, overlay: videoOverlay, scale: 0.5, output: movieURL)

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

    /// 레이아웃 좌표(top-left 기준)의 픽셀 알파값을 샘플링한다.
    static func alphaAtLayoutPoint(_ image: CGImage, _ p: CGPoint, layoutSize: CGSize) -> CGFloat {
        let px = min(image.width - 1, max(0, Int((p.x / layoutSize.width) * CGFloat(image.width))))
        let pyTop = min(image.height - 1, max(0, Int((p.y / layoutSize.height) * CGFloat(image.height))))
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return 1 }
        let yBottom = image.height - 1 - pyTop
        ctx.draw(image, in: CGRect(
            x: CGFloat(-px), y: CGFloat(-yBottom),
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))
        return CGFloat(pixel[3]) / 255
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
