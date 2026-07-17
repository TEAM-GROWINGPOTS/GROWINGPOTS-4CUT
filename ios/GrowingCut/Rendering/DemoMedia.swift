import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

/// 카메라 없는 환경(시뮬레이터, macOS 검증 도구)에서 촬영 결과를 흉내내는 합성 미디어 생성기.
enum DemoMedia {

    /// 기본 프로필 느낌의 회색 톤 — 컷 구분용으로 배경 명도만 살짝 다르게
    private static let grays: [(bg: RGBA, figure: RGBA)] = [
        (.hex(0xF1F1F1), .hex(0xBDBDBD)),
        (.hex(0xEBEBEB), .hex(0xB6B6B6)),
        (.hex(0xE6E6E6), .hex(0xB0B0B0)),
        (.hex(0xF1F1F1), .hex(0xB6B6B6)),
        (.hex(0xEBEBEB), .hex(0xB0B0B0)),
        (.hex(0xE6E6E6), .hex(0xBDBDBD)),
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
        drawScene(index: index, t: 0.4, size: size, motion: false, in: ctx)
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
        drawScene(index: index, t: t, size: sceneSize, motion: true, in: ctx)
        return buffer
    }

    /// top-left 좌표계 전제. 기본 프로필(회색 사람 실루엣) 스타일 자리표시.
    /// motion=true(클립)일 때만 방향 마커·움직임 표시를 그린다 — 합성/회전 검증용.
    private static func drawScene(index: Int, t: Double, size: CGSize, motion: Bool, in ctx: CGContext) {
        let colors = grays[index % grays.count]
        ctx.setFillColor(colors.bg.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // 사람 실루엣: 머리 원 + 어깨 타원 (하단으로 넘치는 부분은 캔버스가 잘라냄)
        ctx.setFillColor(colors.figure.cgColor)
        let headR = size.height * 0.13
        ctx.fillEllipse(in: CGRect(
            x: size.width / 2 - headR, y: size.height * 0.40 - headR,
            width: headR * 2, height: headR * 2
        ))
        ctx.fillEllipse(in: CGRect(
            x: size.width * 0.5 - size.width * 0.34, y: size.height * 0.60,
            width: size.width * 0.68, height: size.height * 0.55
        ))

        // 컷 번호 (은은하게)
        FrameRenderer.drawText(
            "\(index + 1)",
            size: size.height * 0.07, bold: true, kern: 0,
            color: colors.figure.alpha(0.9),
            in: ctx,
            centerX: size.width / 2,
            centerY: size.height * 0.12
        )

        guard motion else { return }

        // 좌상단 방향 마커 (상하/미러 검증용)
        ctx.setFillColor(RGBA.hex(0x8F8F8F).cgColor)
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: size.width * 0.14, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: size.width * 0.14))
        ctx.closePath()
        ctx.fillPath()

        // 좌→우로 움직이는 점 (영상 동작 확인용)
        let cx = size.width * (0.18 + 0.64 * CGFloat(t))
        let r = size.height * 0.05
        ctx.setFillColor(RGBA.hex(0x8F8F8F).alpha(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: size.height * 0.5 - r, width: r * 2, height: r * 2))

        // 하단 진행 바
        ctx.setFillColor(RGBA.hex(0x9F9F9F).alpha(0.55).cgColor)
        ctx.fill(CGRect(x: 0, y: size.height - 18, width: size.width * CGFloat(t), height: 18))
    }
}
