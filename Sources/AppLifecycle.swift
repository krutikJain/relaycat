import AppKit

// Quitting from the Dock or with ⌘Q closes the window and the Dock icon but keeps Relaycat in the
// menu bar, the way ChatGPT and other menu bar apps behave. Quit in the menu bar panel (or ⌥⌘Q)
// quits for real, and so does logging out, restarting or shutting down.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private static var quittingForReal = false
    // Set by a SwiftUI view that has access to openWindow.
    static var openMainWindow: (() -> Void)?

    static var keepsRunningInMenuBar: Bool {
        let d = UserDefaults.standard
        let menuBar = d.object(forKey: "showMenuBar") as? Bool ?? true
        let keep = d.object(forKey: "keepInMenuBar") as? Bool ?? true
        return menuBar && keep
    }

    static var isInMenuBarOnly: Bool { NSApp.activationPolicy() == .accessory }

    static func quitCompletely() {
        quittingForReal = true
        NSApp.terminate(nil)
    }

    static func showMainWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func moveToMenuBar() {
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) {
            w.close()
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.quittingForReal = true }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quittingForReal || Self.isEndingSession || !Self.keepsRunningInMenuBar { return .terminateNow }
        Self.moveToMenuBar()
        return .terminateCancel
    }

    // Opening Relaycat again from Finder, Spotlight or Launchpad while it only lives in the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        guard Self.openMainWindow != nil else {
            NSApp.setActivationPolicy(.regular)
            return true
        }
        Self.showMainWindow()
        return false
    }

    // macOS tags the quit event it sends at logout, restart and shutdown with a reason.
    private static var isEndingSession: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent,
              e.eventClass == AEEventClass(kCoreEventClass), e.eventID == AEEventID(kAEQuitApplication) else { return false }
        let quitReason: AEKeyword = 0x7768_793F // 'why?'
        return e.attributeDescriptor(forKeyword: quitReason) != nil || e.paramDescriptor(forKeyword: quitReason) != nil
    }
}
