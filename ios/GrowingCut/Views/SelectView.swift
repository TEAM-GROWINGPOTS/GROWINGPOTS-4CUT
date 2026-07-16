import SwiftUI
import CoreGraphics

/// 선택 화면 — Figma node 5840:22357 (834×1194) 1:1 구현.
/// 상단 다크 영역(타이머 + 6컷 그리드 + 라이브 미리보기) + 하단 흰 시트(프레임 선택 + CTA).
struct SelectView: View {
    @EnvironmentObject private var model: AppModel

    @State private var selection: [UUID] = []
    @State private var style: FrameStyle = FrameStyle.all[0]
    @State private var previewImage: CGImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var showRetakeConfirm = false

    /// 남은 선택 시간(초). onAppear 전에는 nil → 표시값은 model.selectionSeconds
    @State private var remaining: Int?
    @State private var timerTask: Task<Void, Never>?

    /// 프레임 옵션 카드 x 좌표 (Figma 절대좌표, 폭 124.67 + gap 40)
    private static let optionXs: [CGFloat] = [190.00, 354.67, 519.33]

    var body: some View {
        ZStack {
            Theme.gray800.ignoresSafeArea() // 아트보드 배경 gray-800

            ScaledStage {
                ZStack {
                    bottomSheet
                    timerPill
                    headline
                    retakeButton
                    photoGrid
                    framePreview
                    sheetTitle
                    framePicker
                    ctaButton
                }
            }
        }
        .onAppear {
            startTimer()
            renderPreview()
        }
        .onDisappear {
            timerTask?.cancel()
            renderTask?.cancel()
        }
        .onChange(of: selection) { renderPreview() }
        .onChange(of: style) { renderPreview() }
        .confirmationDialog("처음부터 다시 찍을까요?", isPresented: $showRetakeConfirm, titleVisibility: .visible) {
            Button("다시 찍기", role: .destructive) {
                timerTask?.cancel()
                model.startCapture()
            }
            Button("계속 고르기", role: .cancel) {}
        }
    }

    // MARK: - 상단 다크 영역

    /// 타이머 필 — rect (360, 60, 114, 47), white 10% bg, radius 30
    private var timerPill: some View {
        Text(timeText)
            .font(.pretendard(24, .semiBold))
            .kerning(-0.24)
            .monospacedDigit()
            .foregroundStyle(Color(hex: 0xCECECE)) // gray-300
            .frame(width: 114, height: 47)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 30))
            .position(x: 417, y: 83.5)
    }

    /// 안내 타이틀 — rect (228, 127, 378, 42) 중앙 정렬
    private var headline: some View {
        Text("총 4컷의 사진을 선택해 주세요")
            .font(.pretendard(32, .semiBold))
            .kerning(-0.32)
            .foregroundStyle(.white)
            .position(x: 417, y: 148)
    }

    /// "다시 찍기" — 시안에 없는 유지 요소. 다크 영역 좌상단(패딩 40/60)에 작게 배치
    private var retakeButton: some View {
        Button("다시 찍기") { showRetakeConfirm = true }
            .buttonStyle(GhostButtonStyle(fontSize: 16))
            .padding(.leading, 40)
            .padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 좌측 촬영컷 2행×3열 그리드 — 셀 100×142, gap 12, 원점 (66.83, 256.75)
    private var photoGrid: some View {
        ForEach(Array(model.shots.enumerated()), id: \.element.id) { index, shot in
            shotCell(shot)
                .position(
                    x: 66.83 + CGFloat(index % 3) * 112 + 50,
                    y: 256.75 + CGFloat(index / 3) * 154 + 71
                )
        }
    }

    /// 촬영컷 셀 — 선택 시 lime-300 4pt 안쪽 테두리 + 우하단 순번 배지 (node 5897:25338, 딤·스케일 없음)
    private func shotCell(_ shot: Shot) -> some View {
        let order = selection.firstIndex(of: shot.id)
        return Button {
            toggle(shot.id)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(cg: shot.photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 142)
                    .clipped()
                    .overlay {
                        Rectangle()
                            .strokeBorder(order != nil ? Color(hex: 0xEDFF98) : .clear, lineWidth: 4) // lime-300
                    }

                if let order {
                    Text("\(order + 1)")
                        .font(.pretendard(14, .semiBold))
                        .kerning(-0.14)
                        .foregroundStyle(Color(hex: 0x242424)) // gray-800
                        .frame(width: 20, height: 20)
                        .background(Color(hex: 0xEDFF98), in: Circle()) // lime-300
                        .padding(.trailing, 8)
                        .padding(.bottom, 7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: order)
    }

    /// 우측 라이브 미리보기 — rect (545.83, 208, 221.34, 393.49), 1080×1920 렌더와 종횡비 동일.
    /// 시안의 라임 프레임 목업 자리를 실제 렌더로 대체한다 (기본 프레임 = 라임).
    private var framePreview: some View {
        ZStack {
            Theme.lime500 // 첫 렌더 완료 전 기본 라임 프레임 색
            if let previewImage {
                Image(cg: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
                    .tint(Theme.gray800)
            }
        }
        .frame(width: 221.34, height: 393.49)
        .clipped()
        .position(x: 545.83 + 221.34 / 2, y: 208 + 393.49 / 2)
    }

    // MARK: - 하단 흰 시트

    /// 흰 시트 — rect (0, 675, 834, 519), gray-100, 상단 라운드 20만 적용
    private var bottomSheet: some View {
        UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
            .fill(Color(hex: 0xF4F4F4)) // gray-100
            .frame(width: 834, height: 519)
            .position(x: 417, y: 675 + 519 / 2)
    }

    /// 섹션 타이틀 — rect (0, 715, 834, 42) 중앙 정렬
    private var sheetTitle: some View {
        Text("프레임 선택")
            .font(.pretendard(32, .semiBold))
            .kerning(-0.32)
            .foregroundStyle(Theme.gray800)
            .position(x: 417, y: 736)
    }

    /// 프레임 옵션 3종 — 카드 124.67×221.63, y 787. 선택 시 lime-700 4pt center 스트로크 (node 5897:25437)
    private var framePicker: some View {
        ForEach(Array(FrameStyle.all.enumerated()), id: \.element.id) { index, candidate in
            Button {
                style = candidate
            } label: {
                Image.bundled(candidate.thumbAssetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 124.67, height: 221.63)
                    .clipped()
                    .overlay {
                        if style == candidate {
                            Rectangle().stroke(Color(hex: 0xA6C724), lineWidth: 4) // lime-700
                        }
                    }
            }
            .buttonStyle(.plain)
            .position(x: Self.optionXs[index] + 124.67 / 2, y: 787 + 221.63 / 2)
        }
    }

    /// CTA — rect (304, 1043.63, 226, 88), gray-800 pill, "사진 만들기"
    private var ctaButton: some View {
        Button {
            let picked = selection.compactMap { id in model.shots.first { $0.id == id } }
            guard picked.count == model.pickCount else { return }
            confirm(picked)
        } label: {
            Text("사진 만들기")
                .font(.pretendard(32, .semiBold))
                .foregroundStyle(.white)
                .frame(width: 226, height: 88)
                .background(Theme.gray800, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(selection.count != model.pickCount)
        .opacity(selection.count == model.pickCount ? 1 : 0.4)
        .position(x: 417, y: 1043.63 + 44)
    }

    // MARK: - Logic

    /// 남은 시간 MM:SS 표기
    private var timeText: String {
        let s = remaining ?? model.selectionSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func toggle(_ id: UUID) {
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
        } else if selection.count < model.pickCount {
            selection.append(id)
        }
    }

    /// 40초 카운트다운 시작 — 0이 되면 부족분을 자동으로 채워 바로 진행
    private func startTimer() {
        timerTask?.cancel()
        remaining = model.selectionSeconds
        timerTask = Task { @MainActor in
            while let left = remaining, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining = left - 1
            }
            autoConfirm()
        }
    }

    /// 시간 만료: 현재 선택은 유지하고, 부족분은 촬영 순서(먼저 찍은 컷)대로 채워 확정
    private func autoConfirm() {
        var picked = selection.compactMap { id in model.shots.first { $0.id == id } }
        for shot in model.shots where picked.count < model.pickCount && !picked.contains(shot) {
            picked.append(shot)
        }
        guard picked.count == model.pickCount else { return }
        confirm(picked)
    }

    /// 수동/자동 공통 확정 경로 — 타이머를 먼저 멈추고 넘어간다
    private func confirm(_ picked: [Shot]) {
        timerTask?.cancel()
        model.confirmSelection(picked, style: style)
    }

    /// 선택/프레임 변경 시 미리보기 재렌더 (0.3배, 이전 렌더는 취소)
    private func renderPreview() {
        renderTask?.cancel()
        let shots = model.shots
        let selection = selection
        let style = style
        let pickCount = model.pickCount

        renderTask = Task.detached(priority: .userInitiated) {
            var photos: [CGImage?] = selection.compactMap { id in shots.first { $0.id == id }?.photo }
            while photos.count < pickCount { photos.append(nil) }
            guard let overlay = OverlayLoader.overlay(for: style) else { return }
            let rendered = FrameRenderer.renderStill(
                photos: photos,
                overlay: overlay,
                qr: nil,
                scale: 0.3
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { previewImage = rendered }
        }
    }
}
