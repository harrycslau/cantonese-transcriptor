import AppKit

@MainActor
class HotkeyManager: ObservableObject {
    @Published var isListening = false
    @Published var permissionWarning: String?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var transcriptionManager: TranscriptionManager?

    // Track Left Control state to detect up→down and down→up transitions
    private var isLeftControlDown = false

    private let leftControlKeyCode: UInt16 = 59  // 62 = Right Control (ignored)

    func startListening(transcriptionManager: TranscriptionManager) {
        guard !isListening else { return }
        self.transcriptionManager = transcriptionManager
        isListening = true
        permissionWarning = nil

        // Local monitor: receives events sent to this app
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event  // do not suppress
        }

        // Global monitor: receives events sent to other apps
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        checkPermission()
    }

    func stopListening() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        isListening = false
        isLeftControlDown = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == leftControlKeyCode else { return }
        guard let manager = transcriptionManager else { return }

        let controlDown = event.modifierFlags.contains(.control)

        // Transition: up → down = start recording
        if controlDown && !isLeftControlDown {
            isLeftControlDown = true
            if manager.isRecording || manager.isTranscribing { return }
            manager.startRecording()
        }
        // Transition: down → up = stop and transcribe
        else if !controlDown && isLeftControlDown {
            isLeftControlDown = false
            guard manager.isRecording else { return }
            manager.stopAndTranscribe()
        }
    }

    private func checkPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            permissionWarning = "Push-to-talk may not work while other apps are focused. Enable Accessibility for Transcriptor in System Settings → Privacy & Security → Accessibility."
        }
    }
}