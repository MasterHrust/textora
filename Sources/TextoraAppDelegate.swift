import AppKit

/// LSUIElement + MenuBarExtra: windows are not reliable from `App.init()`, wait for `didFinishLaunching`.
@MainActor
final class TextoraAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.startAfterApplicationReady()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AccessibilityPermissionMonitor.shared.refreshNow()
        AppCoordinator.shared.warmPrimaryInteractionsIfPossible()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.prepareForTermination()
    }

    /// Menu bar (LSUIElement) apps otherwise quit when Settings is closed — no dock icon to "reopen".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
