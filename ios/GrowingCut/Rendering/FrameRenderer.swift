import Foundation
import CoreGraphics
import CoreText

/// 네컷 렌더러. UIKit 의존이 없어 iOS 앱과 macOS 검증 도구에서 동일하게 동작한다.
/// 프레임 디자인은 슬롯·QR창이 투명하게 뚫린 오버레이 PNG로 공급되며,
/// 스틸 이미지(사진 포함)와 영상용 오버레이(슬롯 투명 유지)를 같은 코드로 그린다.
enum FrameRenderer {

    // MARK: - Public API

    /// 최종 네컷 스틸. photos에 nil이 있으면 자리표시(번호)로 그린다.
    static func renderStill(
        photos: [CGImage?],
        overlay: CGImage,
        qr: CGImage?,
        scale: CGFloat = 1.0
    ) -> CGImage? {
        render(photos: photos, overlay: overlay, transparentBase: false, qr: qr, scale: scale)
    }

    /// 영상 합성용 오버레이: 슬롯 영역은 투명 유지, 프레임 크롬 + QR만 그린다.
    static func renderVideoOverlay(
        overlay: CGImage,
        qr: CGImage?,
        scale: CGFloat
    ) -> CGImage? {
        render(photos: [], overlay: overlay, transparentBase: true, qr: qr, scale: scale)
    }

    // MARK: - Core

    private static func render(
        photos: [CGImage?],
        overlay: CGImage,
        transparentBase: Bool,
        qr: CGImage?,
        scale: CGFloat
    ) -> CGImage? {
        let layout = LayoutSpec.standard
        let widthPx = Int((layout.size.width * scale).rounded())
        let heightPx = Int((layout.size.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: widthPx,
                height: heightPx,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // 이후 모든 좌표를 top-left 기준 1080×1920 공간에서 다루도록 CTM을 뒤집는다.
        ctx.translateBy(x: 0, y: CGFloat(heightPx))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)

        if !transparentBase {
            ctx.setFillColor(RGBA.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: layout.size))

            // 사진은 오버레이의 투명 슬롯 아래에 bleed만큼 크게 깔린다
            for (i, rect) in layout.cellRects.enumerated() {
                let bleedRect = rect.insetBy(dx: -layout.cellBleed, dy: -layout.cellBleed)
                if i < photos.count, let photo = photos[i] {
                    drawAspectFill(photo, in: bleedRect, cornerRadius: 0, ctx: ctx)
                } else {
                    drawPlaceholder(index: i, rect: bleedRect, in: ctx)
                }
            }
        }

        drawFullCanvas(overlay, size: layout.size, ctx: ctx)
        drawQRBlock(qr: qr, layout: layout, in: ctx)

        return ctx.makeImage()
    }

    // MARK: - Pieces

    /// 오버레이 PNG를 캔버스 전체에 덮는다 (뒤집힌 CTM 보정)
    private static func drawFullCanvas(_ image: CGImage, size: CGSize, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    private static func drawPlaceholder(index: Int, rect: CGRect, in ctx: CGContext) {
        ctx.setFillColor(RGBA.hex(0xEDEDED).cgColor)
        ctx.fill(rect)
        drawText(
            "\(index + 1)",
            size: 150, bold: true, kern: 0,
            color: RGBA.hex(0xC9C9C9),
            in: ctx,
            centerX: rect.midX,
            centerY: rect.midY
        )
    }

    private static func drawQRBlock(qr: CGImage?, layout: LayoutSpec, in ctx: CGContext) {
        let block = layout.qrRect
        // 라운드 6.498 — Figma 시안 실측값
        let blockPath = CGPath(roundedRect: block, cornerWidth: 6.498, cornerHeight: 6.498, transform: nil)

        ctx.saveGState()
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.addPath(blockPath)
        ctx.fillPath()
        ctx.restoreGState()

        let inner = block.insetBy(dx: layout.qrQuietZone, dy: layout.qrQuietZone)
        if let qr {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            drawAspectFill(qr, in: inner, cornerRadius: 0, ctx: ctx)
            ctx.restoreGState()
        } else {
            drawText(
                "QR",
                size: 44, bold: true, kern: 2,
                color: RGBA.hex(0xBBBBBB),
                in: ctx,
                centerX: block.midX,
                centerY: block.midY
            )
        }
    }

    // MARK: - Drawing helpers (내부 CTM이 top-left로 뒤집힌 상태를 전제)

    /// 이미지를 rect에 aspect-fill로 그린다. 뒤집힌 CTM에서 이미지가 거꾸로 그려지지 않도록 국소적으로 다시 뒤집는다.
    static func drawAspectFill(_ image: CGImage, in rect: CGRect, cornerRadius: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        let clip = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(clip)
        ctx.clip()

        let imgSize = CGSize(width: image.width, height: image.height)
        let s = max(rect.width / imgSize.width, rect.height / imgSize.height)
        let drawSize = CGSize(width: imgSize.width * s, height: imgSize.height * s)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: drawSize))
        ctx.restoreGState()
    }

    /// CoreText 한 줄 그리기. centerX 또는 leftX 중 하나로 가로 위치를 지정한다.
    static func drawText(
        _ text: String,
        size: CGFloat,
        bold: Bool,
        kern: CGFloat,
        color: RGBA,
        in ctx: CGContext,
        centerX: CGFloat? = nil,
        leftX: CGFloat? = nil,
        centerY: CGFloat
    ) {
        let font = uiFont(size: size, bold: bold)
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        if kern != 0 {
            attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern as CFNumber
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        if kern > 0 { width -= kern } // 마지막 글자 뒤 자간 보정

        let x = centerX.map { $0 - width / 2 } ?? (leftX ?? 0)
        let baselineY = centerY + (ascent - descent) / 2

        ctx.saveGState()
        ctx.translateBy(x: x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func uiFont(size: CGFloat, bold: Bool) -> CTFont {
        if let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) {
            return font
        }
        return CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }
}
