import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var helperManager: HelperManager?

    func applicationWillTerminate(_ notification: Notification) {
        helperManager?.stopHelperIfOwned()
    }
}

@main
struct TranscriptorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var helperManager = HelperManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(helperManager)
                .onAppear {
                    appDelegate.helperManager = helperManager
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 500)
    }
}
