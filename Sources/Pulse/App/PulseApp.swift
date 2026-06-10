import AppKit

@main
enum PulseMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        environment = AppEnvironment()
        statusController = StatusItemController(environment: environment)
        environment.scheduler.start()

        if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [statusController] in
                statusController?.showPanelForDebug()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--dump-status") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [statusController] in
                statusController?.dumpStatusForDebug()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
