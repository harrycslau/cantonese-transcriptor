import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApplicationServices

enum TranscriptionState {
    case idle
    case recording(duration: TimeInterval)
    case fileSelected(URL)
    case transcribing
    case success(TranscribeResult)
    case error(String)
}

enum RecordingSource {
    case none
    case manual
    case pushToTalk
}

struct InsertionContext {
    let transcript: String
    let targetApp: NSRunningApplication
}

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var selectedFilePath: String = ""
    @Published var recordingDuration: TimeInterval = 0

    @Published var recordingSource: RecordingSource = .none
    @Published var targetAppBeforeRecording: NSRunningApplication?
    @Published var lastInsertionStatus: String?
    @Published var lastInsertionSucceeded: Bool?

    private var lastInsertionContext: InsertionContext?

    private let client = UnixSocketClient()
    private let audioRecorder = AudioRecorder()
    private var recordingTimer: Timer?
    private var stopping = false

    var canSelectFile: Bool {
        if case .idle = state { return true }
        return false
    }

    var isStopping: Bool {
        return stopping
    }

    var canTranscribe: Bool {
        if case .fileSelected = state {
            return true
        }
        return false
    }

    var isRecording: Bool {
        if case .recording = state {
            return true
        }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = state {
            return true
        }
        return false
    }

    var canRetryInsert: Bool {
        lastInsertionContext != nil && lastInsertionSucceeded == false
    }

    func selectFile() {
        clearInsertionState()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "wav") ?? .audio]
        panel.message = "Select a WAV file to transcribe"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFilePath = url.path
            state = .fileSelected(url)
        }
    }

    func transcribe() {
        guard case .fileSelected(let url) = state else { return }
        clearInsertionState()
        state = .transcribing

        Task {
            var tempPath: String?
            do {
                let transcriptionPath = try prepareAudioForHelper(url)
                tempPath = transcriptionPath
                let result = try await client.transcribe(audioPath: transcriptionPath)
                state = .success(result)
            } catch {
                state = .error(error.localizedDescription)
            }
            if let tempPath {
                try? FileManager.default.removeItem(atPath: tempPath)
            }
        }
    }

    func startRecording(source: RecordingSource, targetApp: NSRunningApplication?) {
        switch state {
        case .idle, .success:
            break
        default:
            return
        }
        selectedFilePath = ""
        recordingDuration = 0
        stopping = false
        clearInsertionState()
        recordingSource = source
        targetAppBeforeRecording = targetApp

        Task {
            do {
                try await audioRecorder.requestPermissionAndRecord()
                state = .recording(duration: 0)
                recordingDuration = 0
                startDurationTimer()
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func stopAndTranscribe() {
        guard case .recording = state, !stopping else { return }
        stopping = true

        recordingTimer?.invalidate()
        recordingTimer = nil

        Task {
            guard let recordingPath = await audioRecorder.stopRecording() else {
                state = .error("Recording failed")
                stopping = false
                return
            }

            if recordingDuration < 1.0 {
                try? FileManager.default.removeItem(atPath: recordingPath)
                state = .error("Recording too short. Please record at least 1 second.")
                stopping = false
                return
            }

            state = .transcribing

            do {
                let result = try await client.transcribe(audioPath: recordingPath)
                state = .success(result)

                if recordingSource == .pushToTalk {
                    insertTranscript(result)
                }
            } catch {
                state = .error(error.localizedDescription)
            }
            try? FileManager.default.removeItem(atPath: recordingPath)
            stopping = false
        }
    }

    func insertTranscript(_ result: TranscribeResult) {
        guard let targetApp = targetAppBeforeRecording else {
            lastInsertionStatus = "No target app"
            lastInsertionSucceeded = false
            return
        }

        if targetApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            clearInsertionState()
            return
        }

        if targetApp.isTerminated {
            lastInsertionStatus = "Target app closed"
            lastInsertionSucceeded = false
            return
        }

        let trimmed = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lastInsertionStatus = "Nothing recorded"
            lastInsertionSucceeded = false
            return
        }

        lastInsertionContext = InsertionContext(transcript: trimmed, targetApp: targetApp)

        guard requestAccessibilityPermissionIfNeeded() else {
            lastInsertionStatus = "Accessibility permission needed. Enable it, then quit and reopen Transcriptor."
            lastInsertionSucceeded = false
            return
        }

        let savedClipboard = ClipboardManager.saveCurrent()
        ClipboardManager.setText(trimmed)
        let transcriptChangeCount = NSPasteboard.general.changeCount

        lastInsertionStatus = "Inserting..."
        lastInsertionSucceeded = nil

        targetApp.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let pasted = ClipboardManager.sendPaste()
            if pasted {
                self.lastInsertionStatus = "Inserted"
                self.lastInsertionSucceeded = true
            } else {
                self.lastInsertionStatus = "Insertion failed"
                self.lastInsertionSucceeded = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let saved = savedClipboard {
                    ClipboardManager.restoreIfUnchanged(saved, expectedChangeCount: transcriptChangeCount)
                }
            }
        }
    }

    func retryInsert() {
        guard let context = lastInsertionContext else { return }

        if context.targetApp.isTerminated {
            lastInsertionStatus = "Target app closed"
            lastInsertionSucceeded = false
            return
        }

        guard requestAccessibilityPermissionIfNeeded() else {
            lastInsertionStatus = "Accessibility permission needed. Enable it, then quit and reopen Transcriptor."
            lastInsertionSucceeded = false
            return
        }

        let savedClipboard = ClipboardManager.saveCurrent()
        ClipboardManager.setText(context.transcript)
        let transcriptChangeCount = NSPasteboard.general.changeCount

        lastInsertionStatus = "Inserting..."
        lastInsertionSucceeded = nil

        context.targetApp.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let pasted = ClipboardManager.sendPaste()
            if pasted {
                self.lastInsertionStatus = "Inserted"
                self.lastInsertionSucceeded = true
            } else {
                self.lastInsertionStatus = "Insertion failed"
                self.lastInsertionSucceeded = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let saved = savedClipboard {
                    ClipboardManager.restoreIfUnchanged(saved, expectedChangeCount: transcriptChangeCount)
                }
            }
        }
    }

    func reset() {
        selectedFilePath = ""
        recordingDuration = 0
        stopping = false
        state = .idle
        clearInsertionState()
    }

    private func startDurationTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration += 0.1
            }
        }
    }

    private func clearInsertionState() {
        lastInsertionStatus = nil
        lastInsertionSucceeded = nil
        lastInsertionContext = nil
        recordingSource = .none
        targetAppBeforeRecording = nil
    }

    private func prepareAudioForHelper(_ url: URL) throws -> String {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selected_\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: url, to: tempURL)
        return tempURL.path
    }

    private func requestAccessibilityPermissionIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        return AXIsProcessTrusted()
    }
}

struct ContentView: View {
    @EnvironmentObject var helperManager: HelperManager
    @StateObject private var manager = TranscriptionManager()
    @StateObject private var hotkeyManager = HotkeyManager()

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let tenths = Int((duration - Double(totalSeconds)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    private var helperStateColor: Color {
        switch helperManager.state {
        case .ready: return .green
        case .starting: return .blue
        case .failed: return .orange
        case .notRunning: return .gray
        }
    }

    private var helperStateLabel: String {
        switch helperManager.state {
        case .ready: return "Helper ready"
        case .starting: return "Starting helper..."
        case .failed: return "Helper failed"
        case .notRunning: return "Helper not running"
        }
    }

    private var helperStatusRow: some View {
        HStack {
            Circle()
                .fill(helperStateColor)
                .frame(width: 8, height: 8)
            Text(helperStateLabel)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if case .failed(let msg) = helperManager.state {
                Button("Retry") {
                    helperManager.startHelper()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if case .notRunning = helperManager.state {
                Button("Start Helper") {
                    helperManager.startHelper()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            if case .starting = helperManager.state {
                ProgressView()
                    .scaleEffect(0.5)
            }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Button("Select WAV File") {
                    manager.selectFile()
                }
                .disabled(!manager.canSelectFile)

                if case .idle = manager.state {
                    Button("Record") {
                        manager.startRecording(source: .manual, targetApp: nil)
                    }
                }

                if manager.isRecording {
                    Button("Stop") {
                        manager.stopAndTranscribe()
                    }
                    .disabled(manager.isStopping)

                    Text("Recording: \(formatDuration(manager.recordingDuration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Image(systemName: "waveform")
                Text("Push-to-talk: hold Left Control")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("Enable", isOn: Binding(
                    get: { hotkeyManager.isListening },
                    set: { enabled in
                        if enabled {
                            hotkeyManager.startListening(transcriptionManager: manager)
                        } else {
                            hotkeyManager.stopListening()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)
            }

            helperStatusRow

            if let warning = hotkeyManager.permissionWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)

                    HStack {
                        Button("Refresh Permission") {
                            hotkeyManager.refreshPermissionStatus()
                        }
                        .font(.caption)

                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            if !manager.selectedFilePath.isEmpty {
                Text(manager.selectedFilePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if manager.canTranscribe {
                Button("Transcribe") {
                    manager.transcribe()
                }
                .buttonStyle(.borderedProminent)
            }

            switch manager.state {
            case .idle:
                Text("Select a WAV file or tap Record to start")
                    .foregroundColor(.secondary)

            case .recording:
                EmptyView()

            case .fileSelected:
                Text("Ready to transcribe")
                    .foregroundColor(.secondary)

            case .transcribing:
                HStack {
                    ProgressView()
                    Text("Transcribing...")
                }

            case .success(let result):
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcript")
                        .font(.headline)
                    ScrollView {
                        Text(result.transcript)
                            .font(.body)
                    }
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)

                    Text("Timing")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Model load", value: String(format: "%.2fs", result.timing.model_load_time_s))
                        LabeledContent("Transcribe", value: String(format: "%.2fs", result.timing.transcribe_time_s))
                        LabeledContent("Audio", value: String(format: "%.2fs", result.timing.audio_duration_s))
                        LabeledContent("RTF", value: String(format: "%.4f", result.timing.real_time_factor))
                    }
                    .font(.caption)

                    if let status = manager.lastInsertionStatus {
                        let isSuccess = status == "Inserted"
                        HStack {
                            Image(systemName: isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                            Text(status)
                                .font(.caption)
                                .foregroundColor(isSuccess ? .green : .orange)
                        }
                        .padding(6)
                        .background(isSuccess ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    HStack {
                        Button("Copy Transcript") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.transcript, forType: .string)
                        }
                        .buttonStyle(.bordered)

                        if manager.canRetryInsert {
                            Button("Retry Insert") {
                                manager.retryInsert()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Button("Transcribe Another") {
                        manager.reset()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)

            case .error(let message):
                Text(message)
                    .foregroundColor(.red)
                    .padding()
                Button("Try Again") {
                    manager.reset()
                }
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .onAppear {
            hotkeyManager.startListening(transcriptionManager: manager)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hotkeyManager.refreshPermissionStatus()
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
