import SwiftUI
import CoreGraphics

struct Shot: Identifiable, Equatable {
    let id = UUID()
    let photo: CGImage
    let clipURL: URL

    static func == (lhs: Shot, rhs: Shot) -> Bool { lhs.id == rhs.id }
}

enum Stage: Equatable {
    case main
    case capture
    case select
    case result
}

@MainActor
final class AppModel: ObservableObject {
    // 촬영 규칙
    let shotCount = 6
    let pickCount = 4
    let countdownSeconds = 5
    /// 선택 화면 제한 시간(초) — 만료 시 부족분을 촬영 순서대로 채워 자동 진행
    let selectionSeconds = 40

    @Published var stage: Stage = .main
    @Published var shots: [Shot] = []
    @Published var picked: [Shot] = []
    @Published var style: FrameStyle = FrameStyle.all[0]

    // 데모 촬영(시뮬레이터/자동 테스트) 진행 상태
    @Published var demoBuilding = false
    @Published var demoError: String?

    @AppStorage("serverBaseURL") var serverBaseURL: String = "http://localhost:8787"
    /// 공개 서버(GC_UPLOAD_KEY 설정 시)용 업로드 키 — 비어 있으면 헤더를 보내지 않는다
    @AppStorage("uploadKey") var uploadKey: String = ""
    // 생성 대기 화면 프로모 QR 링크 (플레이스홀더 — 설정에서 변경)
    @AppStorage("instagramURL") var instagramURL: String = "https://instagram.com/growingpots"
    @AppStorage("landingURL") var landingURL: String = "https://growingcut.vercel.app"

    private(set) var sessionDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("growingcut-session", isDirectory: true)

    // MARK: - 흐름 전환

    func startCapture() {
        resetSessionDir()
        shots = []
        picked = []
        stage = .capture
    }

    func finishCapture(_ newShots: [Shot]) {
        shots = newShots
        stage = .select
    }

    func confirmSelection(_ selection: [Shot], style: FrameStyle) {
        picked = selection
        self.style = style
        // 미선택 컷의 사진 메모리를 즉시 해제 (합성 파이프라인 메모리 여유 확보)
        shots = []
        stage = .result
    }

    func backToMain() {
        stage = .main
    }

    // MARK: - 데모 촬영 (카메라 없이 전체 흐름 확인)

    func startDemoCapture(autoAdvance: Bool = false) {
        guard !demoBuilding else { return }
        resetSessionDir()
        demoBuilding = true
        demoError = nil
        let dir = sessionDir
        let count = shotCount

        Task {
            do {
                var result: [Shot] = []
                for i in 0..<count {
                    guard let photo = DemoMedia.makePhoto(index: i) else {
                        throw NSError(domain: "demo", code: 1, userInfo: [NSLocalizedDescriptionKey: "데모 사진 생성 실패"])
                    }
                    let clipURL = dir.appendingPathComponent("clip\(i).mp4")
                    try await DemoMedia.makeClip(index: i, duration: 4.0, to: clipURL)
                    result.append(Shot(photo: photo, clipURL: clipURL))
                }
                self.shots = result
                self.picked = []
                self.demoBuilding = false
                if autoAdvance {
                    self.confirmSelection(Array(result.prefix(self.pickCount)), style: .byID("lime"))
                } else {
                    self.stage = .select
                }
            } catch {
                self.demoBuilding = false
                self.demoError = error.localizedDescription
            }
        }
    }

    // MARK: - 세션 파일 관리

    private func resetSessionDir() {
        try? FileManager.default.removeItem(at: sessionDir)
        sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("growingcut-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    }

    /// "http://host:port/" → "http://host:port"
    var normalizedBaseURL: String {
        var s = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
