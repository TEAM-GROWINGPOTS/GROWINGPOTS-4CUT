import SwiftUI
import CoreGraphics

enum Theme {
    static let ink = Color(red: 0.16, green: 0.16, blue: 0.20)
    static let pink = Color(red: 1.00, green: 0.36, blue: 0.54)
    static let pinkSoft = Color(red: 1.00, green: 0.85, blue: 0.91)
    static let cream = Color(red: 1.00, green: 0.97, blue: 0.93)

    static var bgGradient: LinearGradient {
        LinearGradient(
            colors: [cream, Color(red: 1.00, green: 0.89, blue: 0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    init(_ rgba: RGBA) {
        self.init(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

extension Image {
    init(cg image: CGImage) {
        self.init(decorative: image, scale: 1, orientation: .up)
    }
}

/// 아이패드 세로 기준(820×1180pt)으로 설계한 화면을 어떤 기기에서든 통째로 축소해 보여준다.
/// 아이폰은 테스트용이므로 '작은 아이패드'처럼 렌더링한다.
struct ScaledStage<Content: View>: View {
    static var designSize: CGSize { CGSize(width: 820, height: 1180) }

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

struct PrimaryButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize * 1.6)
            .padding(.vertical, fontSize * 0.72)
            .background(Theme.pink.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(Capsule())
            .shadow(color: Theme.pink.opacity(0.35), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 19

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.ink.opacity(configuration.isPressed ? 0.5 : 0.8))
            .padding(.horizontal, fontSize * 1.2)
            .padding(.vertical, fontSize * 0.62)
            .background(Theme.ink.opacity(0.06))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
