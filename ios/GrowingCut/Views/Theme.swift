import SwiftUI
import UIKit
import CoreGraphics

/// Figma 디자인 토큰 (growing pots 시안, 파일 hOttl9MCoY4AulqhaUIR2L)
enum Theme {
    // Lime
    static let lime50 = Color(hex: 0xFCFFEE)
    static let lime100 = Color(hex: 0xF7FFD3)
    static let lime200 = Color(hex: 0xF2FFB8)
    static let lime400 = Color(hex: 0xE3FF75)
    static let lime500 = Color(hex: 0xD7F856)
    static let lime600 = Color(hex: 0xC4E936)
    // Gray
    static let gray50 = Color(hex: 0xFAFAFA)
    static let gray600 = Color(hex: 0x474747)
    static let gray700 = Color(hex: 0x373737)
    static let gray800 = Color(hex: 0x242424)
    static let gray900 = Color(hex: 0x191919)

    static let ink = gray900
}

extension Color {
    init(hex v: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(_ rgba: RGBA) {
        self.init(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

// MARK: - 폰트 (Pretendard, 번들 OTF)

enum Pretendard: String {
    case bold = "Pretendard-Bold"
    case semiBold = "Pretendard-SemiBold"
    case regular = "Pretendard-Regular"
}

extension Font {
    static func pretendard(_ size: CGFloat, _ weight: Pretendard = .bold) -> Font {
        .custom(weight.rawValue, fixedSize: size)
    }
}

// MARK: - 이미지 로딩

extension Image {
    init(cg image: CGImage) {
        self.init(decorative: image, scale: 1, orientation: .up)
    }

    /// 번들 리소스 PNG(@2x/@3x)를 로드한다.
    /// synced group 리소스가 번들 루트로 플래튼되는 경우와 폴더가 유지되는 경우를 모두 조회한다.
    static func bundled(_ name: String) -> Image {
        if let ui = UIImage(named: name) { return Image(uiImage: ui) }
        for sub in ["", "Images", "Resources/Images", "Frames", "Resources/Frames"] {
            for scale in [3, 2, 1] {
                let file = scale == 1 ? name : "\(name)@\(scale)x"
                if let url = Bundle.main.url(forResource: file, withExtension: "png", subdirectory: sub.isEmpty ? nil : sub),
                   let data = try? Data(contentsOf: url),
                   let ui = UIImage(data: data, scale: CGFloat(scale)) {
                    return Image(uiImage: ui)
                }
            }
        }
        return Image(systemName: "photo")
    }
}

// MARK: - 스테이지

/// Figma 아트보드(834×1194pt, iPad Pro 11" 세로) 기준으로 설계한 화면을
/// 어떤 기기에서든 통째로 축소/확대해 보여준다. Figma 좌표를 1:1로 옮길 수 있다.
struct ScaledStage<Content: View>: View {
    static var designSize: CGSize { CGSize(width: 834, height: 1194) }

    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let design = Self.designSize
            let scale = min(geo.size.width / design.width, geo.size.height / design.height)
            content
                .frame(width: design.width, height: design.height)
                .scaleEffect(scale)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

// MARK: - 버튼 스타일

/// 검정 캡슐 버튼 (홈 "촬영 시작": Pretendard SemiBold 40, 패딩 52×32, bg gray-800, radius 80)
struct PrimaryButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 40
    var horizontalPadding: CGFloat = 52
    var verticalPadding: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pretendard(fontSize, .semiBold))
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Theme.gray800.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// 반투명 회색 캡슐 버튼 (촬영 "뒤로 가기" 등)
struct GhostButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 20
    var tint: Color = .white
    var background: Color = Color(hex: 0x757575, opacity: 0.72)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pretendard(fontSize, .semiBold))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.horizontal, fontSize * 1.4)
            .padding(.vertical, fontSize * 0.8)
            .background(background)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
