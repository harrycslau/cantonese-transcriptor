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
    @StateObject private var helperManager = HelperManager()
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var hotkeyManager = HotkeyManager()
    @State private var statusBarController: StatusBarController?

    var body: some Scene {
        WindowGroup {
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
                            transcriptionManager: transcriptionManager
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
}
