import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let helperManager: HelperManager
    private let hotkeyManager: HotkeyManager
    private let transcriptionManager: TranscriptionManager
    private let showWindowHandler: () -> Void
    private let hideWindowHandler: () -> Void

    init(
        helperManager: HelperManager,
        hotkeyManager: HotkeyManager,
        transcriptionManager: TranscriptionManager,
        showWindow: @escaping () -> Void,
        hideWindow: @escaping () -> Void
    ) {
        self.helperManager = helperManager
        self.hotkeyManager = hotkeyManager
        self.transcriptionManager = transcriptionManager
        self.showWindowHandler = showWindow
        self.hideWindowHandler = hideWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcriptor")
        statusItem.menu = menu
        menu.delegate = self
    }

    func showWindow() {
        showWindowHandler()
    }

    func hideWindow() {
        hideWindowHandler()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(menuItem("Show Transcriptor", action: #selector(showWindowAction)))
        menu.addItem(menuItem("Hide Window", action: #selector(hideWindowAction)))

        menu.addItem(NSMenuItem.separator())

        let helperItem = NSMenuItem()
        switch helperManager.state {
        case .ready:
            helperItem.title = "Helper: Ready"
        case .starting:
            helperItem.title = "Helper: Starting..."
        case .failed:
            helperItem.title = "Helper: Issue"
        case .notRunning:
            helperItem.title = "Helper: Not running"
        }
        helperItem.isEnabled = false
        menu.addItem(helperItem)

        let pttItem = NSMenuItem()
        pttItem.title = hotkeyManager.isListening ? "Push-to-talk: On" : "Push-to-talk: Off"
        pttItem.isEnabled = false
        menu.addItem(pttItem)

        menu.addItem(menuItem("Toggle Push-to-Talk", action: #selector(togglePushToTalk)))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Quit Transcriptor", action: #selector(quitApp)))
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showWindowAction() {
        showWindow()
    }

    @objc private func hideWindowAction() {
        hideWindow()
    }

    @objc private func togglePushToTalk() {
        Task { @MainActor in
            if hotkeyManager.isListening {
                hotkeyManager.stopListening()
            } else {
                hotkeyManager.startListening(transcriptionManager: transcriptionManager)
            }
        }
    }

    @objc private func quitApp() {
        if helperManager.helperStartedByApp {
            helperManager.stopHelperIfOwned()
        }
        NSApp.terminate(nil)
    }
}
