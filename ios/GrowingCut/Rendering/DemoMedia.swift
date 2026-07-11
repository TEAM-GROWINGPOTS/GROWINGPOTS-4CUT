import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

/// 카메라 없는 환경(시뮬레이터, macOS 검증 도구)에서 촬영 결과를 흉내내는 합성 미디어 생성기.
enum DemoMedia {

    private static let palette: [(bg: RGBA, accent: RGBA)] = [
        (.hex(0xFF8A80), .hex(0xFFFFFF)),
        (.hex(0xFFB74D), .hex(0x5D2E00)),
        (.hex(0xFFF176), .hex(0x6D5A00)),
        (.hex(0xAED581), .hex(0x22430B)),
        (.hex(0x4DD0E1), .hex(0x00363D)),
        (.hex(0x64B5F6), .hex(0x0B3560)),
        (.hex(0xB39DDB), .hex(0x2E1A57)),
        (.hex(0xF48FB1), .hex(0x561329)),
    ]

    /// 세로 3:4 데모 사진 (세로 거치 전면 카메라와 유사한 비율)
    static func makePhoto(index: Int, size: CGSize = CGSize(width: 960, height: 1280)) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        drawScene(index: index, t: 0.4, size: size, in: ctx)
        return ctx.makeImage()
    }

    /// 저장 방향 변형: 카메라 산출물의 preferredTransform 경로 검증용
    enum StoredOrientation {
        case normal
        /// 세로로 저장 + 90° 회전 메타데이터 (세로 촬영 흉내)
        case rotated90
        /// 좌우 미러 메타데이터 (전면 카메라 흉내)
        case mirrored
    }

    /// 세로 3:4 데모 클립. 색/움직임으로 셀 배치와 상하 방향을 검증할 수 있다.
    static func makeClip(
        index: Int,
        duration: Double,
        fps: Int32 = 24,
        size: CGSize = CGSize(width: 540, height: 720),
        orientation: StoredOrientation = .normal,
        to url: URL
    ) async throws {
        // 저장 픽셀 크기: rotated90이면 가로세로가 뒤집힌 채 저장된다
        let stored = orientation == .rotated90 ? CGSize(width: size.height, height: size.width) : size

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(stored.width),
            AVVideoHeightKey: Int(stored.height),
        ])
        input.expectsMediaDataInRealTime = false
        switch orientation {
        case .normal:
            break
        case .rotated90:
            // 표시하려면 90° CW 회전이 필요한 저장물
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: stored.height, ty: 0)
        case .mirrored:
            input.transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: stored.width, ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(stored.width),
                kCVPixelBufferHeightKey as String: Int(stored.height),
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "DemoMedia", code: 1)
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(duration * Double(fps))
        for f in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            let t = Double(f) / Double(max(1, frameCount - 1))
            guard let buffer = makePixelBuffer(
                index: index, t: t, sceneSize: size, storedSize: stored,
                orientation: orientation, pool: adaptor.pixelBufferPool
            ) else {
                throw NSError(domain: "DemoMedia", code: 2)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "DemoMedia", code: 3)
        }
    }

    // MARK: - Drawing

    private static func makePixelBuffer(
        index: Int,
        t: Double,
        sceneSize: CGSize,
        storedSize: CGSize,
        orientation: StoredOrientation,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                nil, Int(storedSize.width), Int(storedSize.height), kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &buffer
            )
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(storedSize.width), height: Int(storedSize.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { return nil }
        ctx.translateBy(x: 0, y: storedSize.height)
        ctx.scaleBy(x: 1, y: -1)
        if orientation == .rotated90 {
            // 장면(sceneSize)을 90° CCW 돌려 저장 → 재생 시 90° CW 회전으로 복원됨
            ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: sceneSize.width))
        }
        drawScene(index: index, t: t, size: sceneSize, in: ctx)
        return buffer
    }

    /// top-left 좌표계 전제. 좌상단 삼각형 마커로 상하/좌우 방향을 검증한다.
    private static func drawScene(index: Int, t: Double, size: CGSize, in ctx: CGContext) {
        let colors = palette[index % palette.count]
        ctx.setFillColor(colors.bg.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // 좌상단 방향 마커
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: size.width * 0.14, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: size.width * 0.14))
        ctx.closePath()
        ctx.fillPath()

        // 좌→우로 움직이는 원
        let cx = size.width * (0.18 + 0.64 * CGFloat(t))
        let r = size.height * 0.16
        ctx.setFillColor(colors.accent.alpha(0.85).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: size.height * 0.5 - r, width: r * 2, height: r * 2))

        FrameRenderer.drawText(
            "CUT \(index + 1)",
            size: size.height * 0.16, bold: true, kern: 4,
            color: colors.accent,
            in: ctx,
            centerX: size.width / 2,
            centerY: size.height * 0.24
        )

        // 하단 진행 바
        ctx.setFillColor(RGBA.white.alpha(0.55).cgColor)
        ctx.fill(CGRect(x: 0, y: size.height - 18, width: size.width * CGFloat(t), height: 18))
    }
}
