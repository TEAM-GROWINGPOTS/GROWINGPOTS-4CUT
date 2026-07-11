import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo

enum VideoComposeError: LocalizedError {
    case missingTrack(URL)
    case readerFailed
    case writerFailed(String)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .missingTrack(let url): return "영상 트랙을 찾을 수 없어요: \(url.lastPathComponent)"
        case .readerFailed: return "영상을 읽는 중 문제가 생겼어요"
        case .writerFailed(let m): return "영상 저장에 실패했어요: \(m)"
        case .renderFailed: return "영상 프레임 합성에 실패했어요"
        }
    }
}

/// 4개의 클립을 스트립 셀 위치에 동시 재생으로 배치하고 프레임 크롬 오버레이를 덮어
/// '움직이는 네컷' 영상을 만든다.
///
/// AVAssetReader → CoreImage 합성 → AVAssetWriter의 완전 인프로세스 파이프라인.
/// (AVMutableComposition/CoreAnimationTool은 iOS·macOS 26에서 deprecated이고
///  CLI 환경에서 동작하지 않아 사용하지 않는다.)
enum VideoComposer {

    /// - Parameters:
    ///   - clipURLs: 셀 순서(위→아래)대로 4개
    ///   - overlay: FrameRenderer.renderVideoOverlay 결과(셀 영역이 투명), scale 배율과 일치해야 함
    ///   - scale: 레이아웃 좌표 → 렌더 픽셀 배율 (0.5 → 600×1800)
    static func compose(
        clipURLs: [URL],
        overlay: CGImage,
        scale: CGFloat = 0.5,
        maxSeconds: Double = 10.0,
        fps: Int32 = 30,
        output: URL
    ) async throws {
        let layout = LayoutSpec.standard
        precondition(clipURLs.count == layout.cellCount, "클립은 셀 개수와 같아야 함")

        let renderSize = CGSize(
            width: (layout.size.width * scale).rounded(),
            height: (layout.size.height * scale).rounded()
        )
        let renderBounds = CGRect(origin: .zero, size: renderSize)
        print("[GC] 영상 합성 시작 renderSize=\(Int(renderSize.width))x\(Int(renderSize.height))")

        // 1) 소스 준비: 디코더 + 셀 배치 정보
        var sources: [ClipSource] = []
        var common = min(maxSeconds, .greatestFiniteMagnitude)
        for (i, url) in clipURLs.enumerated() {
            let source = try await ClipSource(
                url: url,
                cellRect: ciCellRect(layout.cellRects[i], scale: scale, renderHeight: renderSize.height)
            )
            sources.append(source)
            common = min(common, source.duration)
            print("[GC] 클립\(i) 준비됨 (\(String(format: "%.1f", source.duration))s)")
        }
        let frameCount = max(1, Int(common * Double(fps)))
        print("[GC] 총 \(frameCount)프레임 합성")

        // 2) 출력 writer
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoComposeError.writerFailed(writer.error?.localizedDescription ?? "시작 실패")
        }
        writer.startSession(atSourceTime: .zero)

        // 3) 프레임 합성 루프
        let ciContext = CIContext()
        let overlayImage = CIImage(cgImage: overlay)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: renderBounds)

        for f in 0..<frameCount {
            try Task.checkCancellation()
            if f % 60 == 0 { print("[GC] 프레임 \(f)/\(frameCount)") }
            let t = Double(f) / Double(fps)

            var composed = background
            for source in sources {
                if let cellImage = source.image(at: t) {
                    composed = cellImage.composited(over: composed)
                }
            }
            composed = overlayImage.composited(over: composed)

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            var bufferOut: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
            }
            guard let buffer = bufferOut else { throw VideoComposeError.renderFailed }
            ciContext.render(
                composed,
                to: buffer,
                bounds: renderBounds,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }

        for source in sources { source.finish() }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoComposeError.writerFailed(writer.error?.localizedDescription ?? "알 수 없는 오류")
        }
        print("[GC] 영상 합성 완료")
    }

    /// top-left 레이아웃 셀 좌표 → CoreImage(bottom-left) 좌표
    private static func ciCellRect(_ rect: CGRect, scale: CGFloat, renderHeight: CGFloat) -> CGRect {
        let scaled = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
        return CGRect(
            x: scaled.minX,
            y: renderHeight - scaled.maxY,
            width: scaled.width,
            height: scaled.height
        )
    }
}

/// 클립 하나의 순차 디코더. 출력 시각 t에 대응하는 프레임을 셀 위치에 배치한 CIImage로 돌려준다.
private final class ClipSource {
    let duration: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let orientation: CGImagePropertyOrientation
    private let cellRect: CGRect

    private var current: (buffer: CVPixelBuffer, time: Double)?
    private var next: (buffer: CVPixelBuffer, time: Double)?
    private var baseTime: Double?
    private var cachedImage: CIImage?
    private var cachedTime: Double = -1

    init(url: URL, cellRect: CGRect) async throws {
        self.cellRect = cellRect
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoComposeError.missingTrack(url)
        }
        duration = try await asset.load(.duration).seconds
        let preferred = try await track.load(.preferredTransform)
        orientation = Self.exifOrientation(for: preferred)
        let natural = try await track.load(.naturalSize)

        // 셀(최종 절반 스케일)에는 원본 해상도가 과하다 — 절반으로 줄여 디코드해
        // 프레임당 메모리를 1/4로 낮춘다. 스케일 디코드가 거부되면 원본 해상도로 폴백.
        var scaledSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        if natural.width >= 1000 {
            scaledSettings[kCVPixelBufferWidthKey as String] = Int(natural.width / 2)
            scaledSettings[kCVPixelBufferHeightKey as String] = Int(natural.height / 2)
        }

        func makeReader(_ settings: [String: Any]) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            return (reader, output)
        }

        var pair = try makeReader(scaledSettings)
        if !pair.0.startReading() {
            pair = try makeReader([
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            guard pair.0.startReading() else { throw VideoComposeError.readerFailed }
        }
        reader = pair.0
        output = pair.1

        current = pullFrame()
        next = pullFrame()
        guard current != nil else { throw VideoComposeError.readerFailed }
    }

    /// t 시점(0 기준)의 프레임을 셀에 aspect-fill + crop 배치한 CIImage
    func image(at t: Double) -> CIImage? {
        while let n = next, n.time <= t {
            current = n
            next = pullFrame()
        }
        guard let current else { return nil }
        if cachedTime == current.time, let cachedImage { return cachedImage }

        var image = CIImage(cvPixelBuffer: current.buffer).oriented(orientation)
        // 원점 정규화 후 셀에 aspect-fill
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
        let size = image.extent.size
        let s = max(cellRect.width / size.width, cellRect.height / size.height)
        image = image
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(
                translationX: cellRect.midX - size.width * s / 2,
                y: cellRect.midY - size.height * s / 2
            ))
            .cropped(to: cellRect)

        cachedImage = image
        cachedTime = current.time
        return image
    }

    func finish() {
        if reader.status == .reading { reader.cancelReading() }
    }

    private func pullFrame() -> (CVPixelBuffer, Double)? {
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample)
        else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if baseTime == nil { baseTime = pts }
        return (buffer, pts - (baseTime ?? 0))
    }

    /// preferredTransform(자연 좌표 → 표시 좌표)을 EXIF 방향으로 변환.
    /// 90° 단위 회전 + 미러만 다룬다(카메라 산출물의 전형).
    private static func exifOrientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        let mirrored = (t.a * t.d - t.b * t.c) < 0
        switch (angle, mirrored) {
        case (0, false): return .up
        case (90, false): return .right
        case (180, false), (-180, false): return .down
        case (-90, false): return .left
        case (0, true): return .downMirrored
        case (90, true): return .leftMirrored
        case (180, true), (-180, true): return .upMirrored
        case (-90, true): return .rightMirrored
        default: return .up
        }
    }
}
