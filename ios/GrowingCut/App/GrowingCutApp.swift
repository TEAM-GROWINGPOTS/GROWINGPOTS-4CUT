import SwiftUI

@main
struct GrowingCutApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            switch model.stage {
            case .main: MainView()
            case .capture: CaptureView()
            case .select: SelectView()
            case .result: ResultView()
            }
        }
        .task {
            // 자동 데모: 시뮬레이터 E2E 검증용 (simctl launch ... -autoDemo / -demoSelect)
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-autoDemo") {
                model.startDemoCapture(autoAdvance: true)
            } else if args.contains("-demoSelect") {
                model.startDemoCapture(autoAdvance: false)
            }
        }
    }
}
