import CoreGraphics

/// 네컷 인쇄 레이아웃 좌표계: Figma 프레임 시안(1080×1920) 원본 좌표 그대로.
/// 사진 슬롯 4개(2×2)와 QR 창 위치는 오버레이 PNG(frame-*.png)의 투명 영역과 정확히 일치한다.
/// 스틸 이미지와 영상 오버레이가 동일한 스펙을 공유한다.
struct LayoutSpec {
    static let standard = LayoutSpec()

    let size = CGSize(width: 1080, height: 1920)
    let cellSize = CGSize(width: 480, height: 675.5)

    /// 행 우선(왼→오, 위→아래) 순서의 사진 슬롯 — Figma 시안 절대좌표
    var cellRects: [CGRect] {
        [
            CGPoint(x: 44, y: 268.5),
            CGPoint(x: 556, y: 268.5),
            CGPoint(x: 44, y: 976),
            CGPoint(x: 556, y: 976),
        ].map { CGRect(origin: $0, size: cellSize) }
    }

    var cellCount: Int { cellRects.count }

    /// 우상단 QR 창 — Figma 시안 절대좌표
    let qrRect = CGRect(x: 862.84, y: 63, width: 156.76, height: 156.76)
    let qrQuietZone: CGFloat = 10

    /// 슬롯 가장자리 안티앨리어싱(소수점 좌표) 아래로 사진/영상을 밀어넣어 이음새를 가리는 여유
    let cellBleed: CGFloat = 2
}
