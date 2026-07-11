import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: TestResult = .none

    enum TestResult: Equatable { case none, testing, ok, fail }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.0.10:8787", text: model.$serverBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 17, design: .monospaced))

                    Button {
                        testResult = .testing
                        Task {
                            let ok: Bool
                            if let client = try? UploadClient(baseURL: model.normalizedBaseURL) {
                                ok = await client.health()
                            } else {
                                ok = false
                            }
                            testResult = ok ? .ok : .fail
                        }
                    } label: {
                        HStack {
                            Text("연결 테스트")
                            Spacer()
                            switch testResult {
                            case .none: EmptyView()
                            case .testing: ProgressView()
                            case .ok: Label("연결됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .fail: Label("연결 실패", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                } header: {
                    Text("공유 서버 주소")
                } footer: {
                    Text("""
                    맥에서 `node server/server.js`로 서버를 켜면 입력할 주소가 표시돼요. \
                    아이패드(실기기)와 휴대폰은 같은 와이파이에 있어야 QR 링크가 열려요. \
                    업로드된 사진·영상은 4시간 뒤 자동으로 사라져요.
                    """)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
