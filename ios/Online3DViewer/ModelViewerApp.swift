import SwiftUI

@main
struct ModelViewerApp: App {
    @StateObject private var model = ViewerModel()
    @Environment(\.scenePhase) private var scenePhase
    private var benchmarkKeepsAwake: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--benchmark-navigation")
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { model.receiveExternalURL($0) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.setMemoryPressure(1) }
                .onReceive(Timer.publish(every: 1,on: .main,in: .common).autoconnect()) { _ in model.sampleMemoryPolicy() }
                .onChange(of: model.isLoading || model.updatingView || (model.preferences.keepAwake && !model.showingLibrary)) { _, busy in UIApplication.shared.isIdleTimerDisabled = (busy || benchmarkKeepsAwake) && scenePhase == .active }
                .onChange(of: scenePhase) { _, phase in
                    model.foreground = phase == .active
                    UIApplication.shared.isIdleTimerDisabled = phase == .active && (model.isLoading || model.updatingView || benchmarkKeepsAwake || (model.preferences.keepAwake && !model.showingLibrary))
                }
        }
    }
}
