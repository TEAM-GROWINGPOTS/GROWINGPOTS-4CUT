import CoreGraphics

/// UIKit 없이 iOS/macOS 양쪽에서 쓰기 위한 단순 색 표현
struct RGBA: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat = 1

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func alpha(_ v: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: v) }

    static func hex(_ v: UInt32) -> RGBA {
        RGBA(
            r: CGFloat((v >> 16) & 0xFF) / 255,
            g: CGFloat((v >> 8) & 0xFF) / 255,
            b: CGFloat(v & 0xFF) / 255
        )
    }

    static let white = RGBA.hex(0xFFFFFF)
    static let black = RGBA.hex(0x000000)
}

struct FrameStyle: Identifiable, Equatable {
    enum Background: Equatable {
        case solid(RGBA)
        case verticalGradient(RGBA, RGBA) // 위 → 아래
    }

    let id: String
    let name: String
    let background: Background
    let text: RGBA
    let sprockets: Bool        // 필름 구멍 장식
    let cellCornerRadius: CGFloat

    /// 스타일 칩/미리보기에 쓸 대표색
    var swatch: RGBA {
        switch background {
        case .solid(let c): return c
        case .verticalGradient(let a, _): return a
        }
    }

    static let all: [FrameStyle] = [
        FrameStyle(id: "white", name: "화이트", background: .solid(.hex(0xFFFFFF)), text: .hex(0x17171B), sprockets: false, cellCornerRadius: 0),
        FrameStyle(id: "black", name: "블랙", background: .solid(.hex(0x101014)), text: .hex(0xF4F4F6), sprockets: false, cellCornerRadius: 0),
        FrameStyle(id: "film", name: "필름", background: .solid(.hex(0x050505)), text: .hex(0xFFFFFF), sprockets: true, cellCornerRadius: 10),
        FrameStyle(id: "pink", name: "핑크", background: .solid(.hex(0xFFD9E8)), text: .hex(0xC2447A), sprockets: false, cellCornerRadius: 18),
        FrameStyle(id: "sky", name: "스카이", background: .solid(.hex(0xD9ECFF)), text: .hex(0x2A6AB8), sprockets: false, cellCornerRadius: 18),
        FrameStyle(id: "sunset", name: "선셋", background: .verticalGradient(.hex(0xFFDCA8), .hex(0xFF8FA3)), text: .hex(0x86364E), sprockets: false, cellCornerRadius: 18),
    ]

    static func byID(_ id: String) -> FrameStyle {
        all.first { $0.id == id } ?? all[0]
    }
}
