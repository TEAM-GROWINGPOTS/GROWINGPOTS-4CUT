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

/// 인쇄 프레임 변형. 디자인은 슬롯·QR창이 투명하게 뚫린 오버레이 PNG(1080×1920)로 공급된다.
/// 프레임 추가 = 오버레이 PNG 1장 + 썸네일 + 아래 항목 1줄.
struct FrameStyle: Identifiable, Equatable {
    let id: String
    let name: String
    /// 번들 리소스의 오버레이 PNG 이름 (확장자 제외)
    let overlayAssetName: String
    /// 프레임 선택 UI 썸네일 에셋 이름
    let thumbAssetName: String

    static let all: [FrameStyle] = [
        FrameStyle(id: "lime", name: "라임", overlayAssetName: "frame-lime", thumbAssetName: "thumb-frame-lime"),
        FrameStyle(id: "black", name: "블랙", overlayAssetName: "frame-black", thumbAssetName: "thumb-frame-black"),
        FrameStyle(id: "white", name: "화이트", overlayAssetName: "frame-white", thumbAssetName: "thumb-frame-white"),
    ]

    static func byID(_ id: String) -> FrameStyle {
        all.first { $0.id == id } ?? all[0]
    }
}
