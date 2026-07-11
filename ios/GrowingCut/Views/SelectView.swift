import SwiftUI
import CoreGraphics

struct SelectView: View {
    @EnvironmentObject private var model: AppModel

    @State private var selection: [UUID] = []
    @State private var style: FrameStyle = FrameStyle.all[0]
    @State private var previewImage: CGImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var showRetakeConfirm = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd HH:mm"
        return f
    }()

    var body: some View {
        ZStack {
            Theme.bgGradient.ignoresSafeArea()

            ScaledStage {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("마음에 드는 4컷을 골라주세요")
                            .font(.system(size: 33, weight: .black, design: .rounded))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(selection.count) / \(model.pickCount)")
                            .font(.system(size: 27, weight: .heavy, design: .rounded))
                            .foregroundStyle(selection.count == model.pickCount ? Theme.pink : Theme.ink.opacity(0.35))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: selection.count)
                    }

                    HStack(alignment: .top, spacing: 24) {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 18) {
                                photoGrid

                                Text("프레임 고르기")
                                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.top, 4)

                                stylePicker
                            }
                            .padding(.bottom, 8)
                        }

                        stripPreview
                            .frame(width: 236)
                    }

                    Spacer(minLength: 0)

                    HStack {
                        Button("다시 찍기") { showRetakeConfirm = true }
                            .buttonStyle(GhostButtonStyle())
                        Spacer()
                        Button {
                            let picked = selection.compactMap { id in model.shots.first { $0.id == id } }
                            guard picked.count == model.pickCount else { return }
                            model.confirmSelection(picked, style: style)
                        } label: {
                            Label("네컷 만들기", systemImage: "sparkles")
                        }
                        .buttonStyle(PrimaryButtonStyle(fontSize: 24))
                        .disabled(selection.count != model.pickCount)
                        .opacity(selection.count == model.pickCount ? 1 : 0.4)
                    }
                }
                .padding(36)
            }
        }
        .onAppear { renderPreview() }
        .onChange(of: selection) { renderPreview() }
        .onChange(of: style) { renderPreview() }
        .confirmationDialog("처음부터 다시 찍을까요?", isPresented: $showRetakeConfirm, titleVisibility: .visible) {
            Button("다시 찍기", role: .destructive) { model.startCapture() }
            Button("계속 고르기", role: .cancel) {}
        }
    }

    // MARK: - Pieces

    private var stripPreview: some View {
        VStack(spacing: 12) {
            Group {
                if let previewImage {
                    Image(cg: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(LayoutSpec.standard.size.width / LayoutSpec.standard.size.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            Text("미리보기")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.4))
        }
    }

    private var photoGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            ForEach(model.shots) { shot in
                shotCell(shot)
            }
        }
    }

    private func shotCell(_ shot: Shot) -> some View {
        let order = selection.firstIndex(of: shot.id)
        return Button {
            toggle(shot.id)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(cg: shot.photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .opacity(order == nil && selection.count == model.pickCount ? 0.45 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(order != nil ? Theme.pink : .clear, lineWidth: 4)
                    }

                if let order {
                    Text("\(order + 1)")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.pink, in: Circle())
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: order)
    }

    private var stylePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(FrameStyle.all) { candidate in
                    Button {
                        style = candidate
                    } label: {
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(candidate.swatch))
                                .frame(width: 78, height: 96)
                                .overlay {
                                    VStack(spacing: 5) {
                                        ForEach(0..<2, id: \.self) { _ in
                                            HStack(spacing: 5) {
                                                ForEach(0..<2, id: \.self) { _ in
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .fill(Color(candidate.text).opacity(0.35))
                                                        .frame(width: 24, height: 30)
                                                }
                                            }
                                        }
                                    }
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(
                                            style == candidate ? Theme.pink : Theme.ink.opacity(0.12),
                                            lineWidth: style == candidate ? 4 : 1.5
                                        )
                                }
                                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)

                            Text(candidate.name)
                                .font(.system(size: 15, weight: style == candidate ? .heavy : .semibold, design: .rounded))
                                .foregroundStyle(style == candidate ? Theme.pink : Theme.ink.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Logic

    private func toggle(_ id: UUID) {
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
        } else if selection.count < model.pickCount {
            selection.append(id)
        }
    }

    private func renderPreview() {
        renderTask?.cancel()
        let shots = model.shots
        let selection = selection
        let style = style
        let dateText = Self.dateFormatter.string(from: Date())

        renderTask = Task.detached(priority: .userInitiated) {
            var photos: [CGImage?] = selection.compactMap { id in shots.first { $0.id == id }?.photo }
            while photos.count < 4 { photos.append(nil) }
            let rendered = FrameRenderer.renderStill(
                photos: photos,
                style: style,
                qr: nil,
                dateText: dateText,
                scale: 0.3
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { previewImage = rendered }
        }
    }
}
