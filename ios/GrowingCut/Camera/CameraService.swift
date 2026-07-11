import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// 전면 카메라 세션. 10초 클립 녹화(무음)와 스틸 촬영을 동시에 담당한다.
/// 미리보기와 동일하게 보이도록 전면 카메라 산출물은 미러링해 저장한다.
final class CameraService: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case configuring
        case ready
        case denied
        case unavailable   // 시뮬레이터 등
        case failed(String)
    }

    enum CameraError: LocalizedError {
        case notReady
        case noDevice
        case cannotAddIO
        case decodeFailed
        case recordingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReady: return "카메라가 아직 준비되지 않았어요"
            case .noDevice: return "사용할 수 있는 카메라가 없어요"
            case .cannotAddIO: return "카메라 입출력 구성에 실패했어요"
            case .decodeFailed: return "사진 처리에 실패했어요"
            case .recordingFailed(let m): return "영상 녹화에 문제가 생겼어요: \(m)"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    /// 촬영 소스 가로/세로 비율 (저장 영역 가이드 계산용)
    @Published private(set) var sourceAspect: CGFloat = 0

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "growingcut.camera.session")
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    // 진행 중인 캡처의 continuation (sessionQueue에서만 접근)
    private var photoContinuation: CheckedContinuation<CGImage, Error>?
    private var movieContinuation: CheckedContinuation<URL, Error>?

    // MARK: - Lifecycle

    func configure() async {
        #if targetEnvironment(simulator)
        await set(.unavailable)
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                await set(.denied)
                return
            }
        default:
            await set(.denied)
            return
        }

        await set(.configuring)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    do {
                        try self.configureOnQueue()
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
            await MainActor.run {
                attachRotationCoordinatorIfPossible()
                status = .ready
            }
        } catch {
            await set(.failed(error.localizedDescription))
        }
        #endif
    }

    private func configureOnQueue() throws {
        guard !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        else {
            session.commitConfiguration()
            throw CameraError.noDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddIO
        }
        session.addInput(input)
        guard session.canAddOutput(photoOutput), session.canAddOutput(movieOutput) else {
            session.commitConfiguration()
            throw CameraError.cannotAddIO
        }
        session.addOutput(photoOutput)
        session.addOutput(movieOutput)
        session.commitConfiguration()

        self.device = device
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        DispatchQueue.main.async {
            self.sourceAspect = CGFloat(dims.width) / CGFloat(dims.height)
        }
        session.startRunning()
    }

    func stop() {
        sessionQueue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - Preview / rotation

    @MainActor
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        attachRotationCoordinatorIfPossible()
    }

    @MainActor
    private func attachRotationCoordinatorIfPossible() {
        guard rotationCoordinator == nil, let device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak previewLayer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    /// 캡처 직전 연결 설정: 수평 기준 회전 + 전면 미러
    private func prepareOnQueue(_ connection: AVCaptureConnection) {
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if device?.position == .front, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    // MARK: - Capture

    func startRecording(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                guard self.session.isRunning, !self.movieOutput.isRecording else {
                    cont.resume(throwing: CameraError.notReady)
                    return
                }
                if let connection = self.movieOutput.connection(with: .video) {
                    self.prepareOnQueue(connection)
                }
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                cont.resume()
            }
        }
    }

    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            sessionQueue.async {
                guard self.movieOutput.isRecording else {
                    cont.resume(throwing: CameraError.recordingFailed("녹화 중이 아니에요"))
                    return
                }
                self.movieContinuation = cont
                self.movieOutput.stopRecording()
            }
        }
    }

    func capturePhoto() async throws -> CGImage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            sessionQueue.async {
                guard self.session.isRunning else {
                    cont.resume(throwing: CameraError.notReady)
                    return
                }
                if let connection = self.photoOutput.connection(with: .video) {
                    self.prepareOnQueue(connection)
                }
                self.photoContinuation = cont
                self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    // MARK: - Helpers

    private func set(_ newStatus: Status) async {
        await MainActor.run { status = newStatus }
    }

    /// EXIF 방향(미러 포함)을 픽셀에 구운 CGImage로 디코드.
    /// 셀 목표 폭(1080px)보다 넉넉한 정도로만 디코드해 메모리를 아낀다.
    static func decodeOriented(_ data: Data, maxPixel: Int = 1600) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        sessionQueue.async {
            guard let cont = self.photoContinuation else { return }
            self.photoContinuation = nil
            if let error {
                cont.resume(throwing: error)
                return
            }
            guard let data = photo.fileDataRepresentation(),
                  let image = Self.decodeOriented(data)
            else {
                cont.resume(throwing: CameraError.decodeFailed)
                return
            }
            cont.resume(returning: image)
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {}

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async {
            guard let cont = self.movieContinuation else { return }
            self.movieContinuation = nil
            if let error = error as NSError? {
                // maxDuration 도달 등은 성공 플래그와 함께 error가 올 수 있다
                let finished = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
                if !finished {
                    cont.resume(throwing: CameraError.recordingFailed(error.localizedDescription))
                    return
                }
            }
            cont.resume(returning: outputFileURL)
        }
    }
}
