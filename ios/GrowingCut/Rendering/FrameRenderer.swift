import Foundation
import CoreGraphics
import CoreText

/// 4컷 스트립 렌더러. UIKit 의존이 없어 iOS 앱과 macOS 검증 도구에서 동일하게 동작한다.
/// 스틸 이미지(사진 포함)와 영상용 오버레이(셀 영역이 투명으로 뚫린 크롬)를 같은 코드로 그린다.
enum FrameRenderer {

    // MARK: - Public API

    /// 최종 4컷 스틸 이미지. photos에 nil이 있으면 자리표시(번호)로 그린다.
    static func renderStill(
        photos: [CGImage?],
        style: FrameStyle,
        qr: CGImage?,
        dateText: String,
        scale: CGFloat = 1.0
    ) -> CGImage? {
        render(style: style, photos: photos, punchCells: false, qr: qr, dateText: dateText, scale: scale)
    }

    /// 영상 합성용 오버레이: 프레임 크롬(배경/QR/문구)은 그대로, 4개 셀 영역만 투명으로 뚫는다.
    static func renderVideoOverlay(
        style: FrameStyle,
        qr: CGImage?,
        dateText: String,
        scale: CGFloat
    ) -> CGImage? {
        render(style: style, photos: [], punchCells: true, qr: qr, dateText: dateText, scale: scale)
    }

    // MARK: - Core

    private static func render(
        style: FrameStyle,
        photos: [CGImage?],
        punchCells: Bool,
        qr: CGImage?,
        dateText: String,
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

        // 이후 모든 좌표를 top-left 기준 1200×3600 공간에서 다루도록 CTM을 뒤집는다.
        ctx.translateBy(x: 0, y: CGFloat(heightPx))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)

        drawBackground(style: style, layout: layout, in: ctx)
        if style.sprockets {
            drawSprockets(layout: layout, in: ctx)
        }

        for (i, rect) in layout.cellRects.enumerated() {
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: style.cellCornerRadius,
                cornerHeight: style.cellCornerRadius,
                transform: nil
            )
            if punchCells {
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.restoreGState()
            } else if i < photos.count, let photo = photos[i] {
                drawAspectFill(photo, in: rect, cornerRadius: style.cellCornerRadius, ctx: ctx)
            } else {
                drawPlaceholder(index: i, rect: rect, path: path, style: style, in: ctx)
            }
        }

        drawQRBlock(qr: qr, layout: layout, in: ctx)

        // 헤더 좌측 로고
        drawText(
            "GROWING CUT",
            size: 46, bold: true, kern: 6,
            color: style.text,
            in: ctx,
            leftX: layout.sideMargin,
            centerY: layout.headerHeight / 2
        )

        // 하단 브랜딩 + 날짜
        drawText(
            "GROWING CUT",
            size: 88, bold: true, kern: 9,
            color: style.text,
            in: ctx,
            centerX: layout.size.width / 2,
            centerY: layout.bottomRect.minY + 130
        )
        drawText(
            dateText,
            size: 36, bold: false, kern: 3,
            color: style.text.alpha(0.55),
            in: ctx,
            centerX: layout.size.width / 2,
            centerY: layout.bottomRect.minY + 218
        )

        return ctx.makeImage()
    }

    // MARK: - Pieces

    private static func drawBackground(style: FrameStyle, layout: LayoutSpec, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: layout.size)
        switch style.background {
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(full)
        case .verticalGradient(let top, let bottom):
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let gradient = CGGradient(
                    colorsSpace: space,
                    colors: [top.cgColor, bottom.cgColor] as CFArray,
                    locations: [0, 1]
                  )
            else { return }
            ctx.saveGState()
            ctx.addRect(full)
            ctx.clip()
            // CTM이 뒤집혀 있으므로 (0,0)이 화면상 최상단
            ctx.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: layout.size.height),
                options: []
            )
            ctx.restoreGState()
        }
    }

    private static func drawSprockets(layout: LayoutSpec, in ctx: CGContext) {
        let holeSize = CGSize(width: 30, height: 42)
        let leftX = (layout.sideMargin - holeSize.width) / 2
        let rightX = layout.size.width - layout.sideMargin + leftX
        let startY = layout.headerHeight + 20
        let endY = layout.bottomRect.minY - 20 - holeSize.height
        ctx.setFillColor(RGBA.white.alpha(0.92).cgColor)
        var y = startY
        while y <= endY {
            for x in [leftX, rightX] {
                let path = CGPath(
                    roundedRect: CGRect(x: x, y: y, width: holeSize.width, height: holeSize.height),
                    cornerWidth: 8, cornerHeight: 8, transform: nil
                )
                ctx.addPath(path)
                ctx.fillPath()
            }
            y += 130
        }
    }

    private static func drawPlaceholder(index: Int, rect: CGRect, path: CGPath, style: FrameStyle, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(style.text.alpha(0.07).cgColor)
        ctx.fill(rect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(style.text.alpha(0.22).cgColor)
        ctx.setLineWidth(3)
        ctx.setLineDash(phase: 0, lengths: [16, 12])
        ctx.strokePath()
        ctx.restoreGState()

        drawText(
            "\(index + 1)",
            size: 150, bold: true, kern: 0,
            color: style.text.alpha(0.18),
            in: ctx,
            centerX: rect.midX,
            centerY: rect.midY
        )
    }

    private static func drawQRBlock(qr: CGImage?, layout: LayoutSpec, in ctx: CGContext) {
        let block = layout.qrBlockRect
        let blockPath = CGPath(roundedRect: block, cornerWidth: 24, cornerHeight: 24, transform: nil)

        ctx.saveGState()
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.addPath(blockPath)
        ctx.fillPath()
        ctx.setStrokeColor(RGBA.hex(0x999999).alpha(0.5).cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(blockPath)
        ctx.strokePath()
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
                size: 56, bold: true, kern: 2,
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
