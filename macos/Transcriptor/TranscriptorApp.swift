import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var helperManager: HelperManager?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        helperManager?.stopHelperIfOwned()
    }
}

@main
struct TranscriptorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var helperManager = HelperManager()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var hotkeyManager = HotkeyManager()
    @State private var statusBarController: StatusBarController?

    var body: some Scene {
        WindowGroup("Transcriptor", id: "main") {
            ContentView()
                .environmentObject(helperManager)
                .environmentObject(transcriptionManager)
                .environmentObject(hotkeyManager)
                .onAppear {
                    appDelegate.helperManager = helperManager
                    if statusBarController == nil {
                        statusBarController = StatusBarController(
                            helperManager: helperManager,
                            hotkeyManager: hotkeyManager,
                            transcriptionManager: transcriptionManager,
                            showWindow: showMainWindow,
                            hideWindow: hideMainWindow
                        )
                    }
                    if !hotkeyManager.isListening {
                        hotkeyManager.startListening(transcriptionManager: transcriptionManager)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 480)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        activateMainWindow()
    }

    private func hideMainWindow() {
        if let window = NSApp.windows.first(where: { !$0.isMiniaturized && $0.canBecomeKey }) {
            window.orderOut(nil)
        }
    }

    private func activateMainWindow(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey && $0.level == .normal }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if attempt < 5 {
                activateMainWindow(attempt: attempt + 1)
            }
        }
    }
}
