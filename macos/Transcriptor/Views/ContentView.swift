import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum TranscriptionState {
    case idle
    case recording(duration: TimeInterval)
    case fileSelected(URL)
    case transcribing
    case success(TranscribeResult)
    case error(String)
}

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var selectedFilePath: String = ""
    @Published var recordingDuration: TimeInterval = 0

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

    func selectFile() {
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
        state = .transcribing

        Task {
            do {
                let result = try await client.transcribe(audioPath: url.path)
                state = .success(result)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func startRecording() {
        guard case .idle = state else { return }

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

        let path = audioRecorder.stopRecording()

        guard let recordingPath = path else {
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

        Task {
            do {
                let result = try await client.transcribe(audioPath: recordingPath)
                state = .success(result)
            } catch {
                state = .error(error.localizedDescription)
            }
            try? FileManager.default.removeItem(atPath: recordingPath)
            stopping = false
        }
    }

    func reset() {
        selectedFilePath = ""
        recordingDuration = 0
        stopping = false
        state = .idle
    }

    private func startDurationTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration += 0.1
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var manager = TranscriptionManager()

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let tenths = Int((duration - Double(totalSeconds)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
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
                        manager.startRecording()
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
    }
}