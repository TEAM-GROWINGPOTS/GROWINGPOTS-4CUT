import CoreGraphics

/// 네컷 레이아웃 좌표계: 세로 4:3(가로:세로 = 3:4) 셀 4개를 2×2 그리드로 배열.
/// 모든 값은 top-left 기준 캔버스(1200×2048pt) 좌표이며, 렌더 시 scale을 곱해 픽셀로 변환한다.
/// 스틸 이미지와 영상 오버레이가 동일한 스펙을 공유한다.
struct LayoutSpec {
    static let standard = LayoutSpec()

    let canvasWidth: CGFloat = 1200
    let sideMargin: CGFloat = 60
    let headerHeight: CGFloat = 280
    let bottomHeight: CGFloat = 340
    let cellGap: CGFloat = 40
    let columns = 2
    let rows = 2

    let qrBlockSize: CGFloat = 200
    let qrQuietZone: CGFloat = 14

    var cellCount: Int { columns * rows }

    /// 셀: 세로 4:3 (3:4 w:h). 높이는 0.5배 영상 렌더에서도 짝수가 되도록 4의 배수로 반올림.
    var cellSize: CGSize {
        let width = (canvasWidth - 2 * sideMargin - CGFloat(columns - 1) * cellGap) / CGFloat(columns)
        let rawHeight = width * 4 / 3
        let height = (rawHeight / 4).rounded() * 4
        return CGSize(width: width, height: height)
    }

    var size: CGSize {
        CGSize(
            width: canvasWidth,
            height: headerHeight
                + CGFloat(rows) * cellSize.height
                + CGFloat(rows - 1) * cellGap
                + bottomHeight
        )
    }

    /// 행 우선(왼→오, 위→아래) 순서의 셀 영역
    var cellRects: [CGRect] {
        (0..<cellCount).map { i in
            let row = i / columns
            let col = i % columns
            return CGRect(
                origin: CGPoint(
                    x: sideMargin + CGFloat(col) * (cellSize.width + cellGap),
                    y: headerHeight + CGFloat(row) * (cellSize.height + cellGap)
                ),
                size: cellSize
            )
        }
    }

    /// 우측 상단 QR 블록(흰 배경 포함) 영역
    var qrBlockRect: CGRect {
        CGRect(
            x: size.width - sideMargin - qrBlockSize,
            y: (headerHeight - qrBlockSize) / 2,
            width: qrBlockSize,
            height: qrBlockSize
        )
    }

    var bottomRect: CGRect {
        CGRect(x: 0, y: size.height - bottomHeight, width: size.width, height: bottomHeight)
    }
}
