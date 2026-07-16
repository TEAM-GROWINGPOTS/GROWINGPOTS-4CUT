import Foundation
import CoreGraphics
import ImageIO

/// 프레임 오버레이 PNG 로더. UIKit 의존이 없어 iOS 번들과 macOS 도구가 같은 코드를 쓴다.
enum OverlayLoader {
    private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()

    /// 파일 URL에서 CGImage 로드 (ImageIO)
    static func load(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 스타일의 오버레이 PNG를 번들에서 찾아 로드한다 (최초 1회 로드 후 캐시, 3종 × ~8MB).
    /// synced group 리소스가 번들 루트로 플래튼되는 경우와 폴더가 유지되는 경우를 모두 조회한다.
    static func overlay(for style: FrameStyle, bundle: Bundle = .main) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[style.overlayAssetName] { return cached }
        let candidates = [
            bundle.url(forResource: style.overlayAssetName, withExtension: "png"),
            bundle.url(forResource: style.overlayAssetName, withExtension: "png", subdirectory: "Frames"),
            bundle.url(forResource: style.overlayAssetName, withExtension: "png", subdirectory: "Resources/Frames"),
        ]
        guard let url = candidates.compactMap({ $0 }).first,
              let image = load(url: url)
        else { return nil }
        cache[style.overlayAssetName] = image
        return image
    }
}
