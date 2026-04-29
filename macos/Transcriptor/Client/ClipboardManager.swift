import AppKit
import ApplicationServices

class ClipboardManager {
    struct SavedClipboard {
        let string: String?
        let changeCount: Int
    }

    static func saveCurrent() -> SavedClipboard? {
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) != nil else { return nil }
        return SavedClipboard(
            string: pasteboard.string(forType: .string),
            changeCount: pasteboard.changeCount
        )
    }

    @discardableResult
    static func setText(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    static func restoreIfUnchanged(_ saved: SavedClipboard, expectedChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else { return }
        if let string = saved.string {
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }
    }

    @discardableResult
    static func sendPaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9  // 'V' key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}