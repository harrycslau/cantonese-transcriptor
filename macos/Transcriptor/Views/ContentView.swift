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

enum TranscribingSource {
    case file
    case recording
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
    @Published var transcribingSource: TranscribingSource = .recording
    @Published var transcribingElapsed: TimeInterval = 0
    @Published var chunkProgress: ChunkProgress?

    private var lastInsertionContext: InsertionContext?

    private let client = UnixSocketClient()
    private let audioRecorder = AudioRecorder()
    private var recordingTimer: Timer?
    private var transcribingTimer: Timer?
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

    var latestTranscript: String {
        if case .success(let result) = state {
            return result.transcript
        }
        return ""
    }

    var latestTiming: TimingInfo? {
        if case .success(let result) = state {
            return result.timing
        }
        return nil
    }

    var insertionAppName: String? {
        lastInsertionContext?.targetApp.localizedName
    }

    var formattedInsertionStatus: String? {
        guard let status = lastInsertionStatus else { return nil }
        let appName = insertionAppName ?? "app"
        switch status {
        case "Inserted":
            return "Inserted into \(appName)"
        case "Insertion failed":
            return "Could not insert into \(appName)"
        case "Accessibility permission needed. Enable it, then quit and reopen Transcriptor.":
            return "Could not insert into \(appName): Accessibility permission needed"
        case "Target app closed":
            return "Could not insert into \(appName): target closed"
        default:
            return status
        }
    }

    func selectFile() {
        clearInsertionState()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "wav") ?? .audio,
            UTType(filenameExtension: "mp3") ?? .audio,
            UTType(filenameExtension: "m4a") ?? .mpeg4Audio,
        ]
        panel.message = "Select a WAV, MP3, or M4A file to transcribe"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFilePath = url.path
            state = .fileSelected(url)
        }
    }

    func transcribeChunked() {
        guard case .fileSelected(let url) = state else { return }
        clearInsertionState()
        transcribingSource = .file
        chunkProgress = nil
        startTranscribingTimer()
        state = .transcribing

        Task {
            var tempPath: String?
            do {
                let transcriptionPath = try prepareAudioForHelper(url)
                tempPath = transcriptionPath
                let result = try await client.transcribeFileChunked(audioPath: transcriptionPath) { progress in
                    Task { @MainActor in
                        self.chunkProgress = progress
                    }
                }
                stopTranscribingTimer()
                chunkProgress = nil
                state = .success(result)
            } catch let error as SocketClientError {
                stopTranscribingTimer()
                chunkProgress = nil
                if case .connectionTimedOut = error {
                    state = .error("Helper is still processing or did not respond. Large files can take several minutes.")
                } else {
                    state = .error(error.localizedDescription)
                }
            } catch {
                stopTranscribingTimer()
                chunkProgress = nil
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
            transcribingSource = .recording
            startTranscribingTimer()

            do {
                let result = try await client.transcribe(audioPath: recordingPath, timeout: .shortRecording)
                stopTranscribingTimer()
                state = .success(result)

                if recordingSource == .pushToTalk {
                    insertTranscript(result)
                }
            } catch {
                stopTranscribingTimer()
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
        stopTranscribingTimer()
        transcribingElapsed = 0
        transcribingSource = .recording
        selectedFilePath = ""
        recordingDuration = 0
        stopping = false
        chunkProgress = nil
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

    private func startTranscribingTimer() {
        transcribingElapsed = 0
        transcribingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.transcribingElapsed += 1.0
            }
        }
    }

    private func stopTranscribingTimer() {
        transcribingTimer?.invalidate()
        transcribingTimer = nil
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

        let ext = url.pathExtension.lowercased()
        let safeExt = ["wav", "mp3", "m4a"].contains(ext) ? ext : "wav"
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("selected_\(UUID().uuidString).\(safeExt)")
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
    @EnvironmentObject var manager: TranscriptionManager
    @EnvironmentObject var hotkeyManager: HotkeyManager

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
        HStack(spacing: 6) {
            Circle()
                .fill(helperStateColor)
                .frame(width: 8, height: 8)
            Text(helperStateLabel)
                .font(.caption)
                .foregroundColor(.secondary)

            if hotkeyManager.permissionWarning != nil {
                Button {
                    openAccessibilitySettings()
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .help("Accessibility permission needed for auto-insert")
            }

            Spacer()

            if case .failed(let msg) = helperManager.state {
                Button("Retry") {
                    helperManager.startHelper()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                Text(msg.count > 40 ? String(msg.prefix(40)) + "..." : msg)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
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

    private var headerRow: some View {
        HStack {
            helperStatusRow
            Spacer()
            Toggle("PTT", isOn: Binding(
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
    }

    private var primaryArea: some View {
        VStack(spacing: 8) {
            switch manager.state {
            case .idle:
                VStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("Hold ⌃ to dictate")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

            case .recording:
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.title)
                        .foregroundColor(.red)
                    Text(formatDuration(manager.recordingDuration))
                        .font(.title2.monospacedDigit())
                    Text("Release to transcribe")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

            case .transcribing:
                VStack(spacing: 6) {
                    ProgressView()
                    if manager.transcribingSource == .file {
                        if let progress = manager.chunkProgress {
                            Text("Transcribing chunk \(progress.current) of \(progress.total) (\(progress.stage))... \(formatDuration(manager.transcribingElapsed))")
                        } else {
                            Text("Transcribing file... \(formatDuration(manager.transcribingElapsed)) elapsed")
                        }
                        Text("Large files may take several minutes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Transcribing...")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

            case .fileSelected:
                VStack(spacing: 4) {
                    Text("Ready to transcribe")
                        .foregroundColor(.secondary)
                    Text(manager.selectedFilePath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

            case .success:
                EmptyView()

            case .error(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        manager.reset()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest transcript")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                Text(manager.latestTranscript)
                    .font(.body)
            }
            .frame(maxHeight: 100)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)

            if let status = manager.formattedInsertionStatus {
                let isSuccess = status == "Inserted into \(manager.insertionAppName ?? "app")"
                HStack(spacing: 4) {
                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(isSuccess ? .green : .orange)
                    Text(status)
                        .font(.caption)
                        .foregroundColor(isSuccess ? .green : .orange)
                }
            }

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.latestTranscript, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                if manager.canRetryInsert {
                    Button("Retry Insert") {
                        manager.retryInsert()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Clear") {
                    manager.reset()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }

            if let timing = manager.latestTiming {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Load", value: String(format: "%.2fs", timing.model_load_time_s))
                    LabeledContent("Transcribe", value: String(format: "%.2fs", timing.transcribe_time_s))
                    LabeledContent("Audio", value: String(format: "%.2fs", timing.audio_duration_s))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button("Select Audio File") {
                manager.selectFile()
            }
            .buttonStyle(.bordered)
            .disabled(manager.isRecording || manager.isTranscribing)

            if case .idle = manager.state {
                Button("Record") {
                    manager.startRecording(source: .manual, targetApp: nil)
                }
                .buttonStyle(.bordered)
            }

            if manager.isRecording {
                Button("Stop") {
                    manager.stopAndTranscribe()
                }
                .buttonStyle(.bordered)
                .disabled(manager.isStopping)
            }

            if manager.canTranscribe {
                Button("Transcribe") {
                    manager.transcribeChunked()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            headerRow

            primaryArea

            if case .success = manager.state {
                Divider()
                resultArea
                Divider()
            }

            footerRow
        }
        .padding()
        .frame(width: 520, height: 480)
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
