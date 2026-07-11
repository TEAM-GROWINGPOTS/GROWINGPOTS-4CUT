import CoreGraphics
import CoreImage

enum QRCode {
    /// 문자열을 QR CGImage로. 모듈 경계가 뭉개지지 않도록 nearest-neighbor 정수 배율로 확대한다.
    static func generate(_ string: String, targetSize: Int = 512) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = max(1, (CGFloat(targetSize) / output.extent.width).rounded(.down))
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
