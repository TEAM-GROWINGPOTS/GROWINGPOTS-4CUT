import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// 미디어 파일 검증 도구
///   probe <video> <출력 디렉터리>  → 길이/크기 출력 + 프레임 3장 PNG 추출
///   probe --qr <image>            → 이미지 속 QR 디코드
@main
struct Probe {
    static func main() async {
        do {
            if CommandLine.arguments[1] == "--qr" {
                let url = URL(fileURLWithPath: CommandLine.arguments[2])
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
                else {
                    print("QR FAIL: 이미지를 열 수 없음")
                    exit(1)
                }
                let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
                let messages = (detector?.features(in: CIImage(cgImage: image)) ?? [])
                    .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                print(messages.isEmpty ? "QR FAIL: 코드 없음" : "QR DECODED: \(messages.joined(separator: ", "))")
                exit(messages.isEmpty ? 1 : 0)
            }

            let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let asset = AVURLAsset(url: videoURL)
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                print("PROBE FAIL: no video track")
                exit(1)
            }
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            print(String(format: "PROBE OK duration=%.2fs size=%.0fx%.0f fps=%.1f", duration, size.width, size.height, fps))

            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let times = [duration * 0.1, duration * 0.5, duration * 0.9]
            for (i, t) in times.enumerated() {
                let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                let dest = outDir.appendingPathComponent("probe-frame\(i).png")
                guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    print("PROBE FAIL: png dest")
                    exit(1)
                }
                CGImageDestinationAddImage(d, image, nil)
                CGImageDestinationFinalize(d)
            }
            print("FRAMES OK")
        } catch {
            print("PROBE FAIL: \(error)")
            exit(1)
        }
    }
}
