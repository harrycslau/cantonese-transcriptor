import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum TranscriptionState {
    case idle
    case fileSelected(URL)
    case transcribing
    case success(TranscribeResult)
    case error(String)
}

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var state: TranscriptionState = .idle
    @Published var selectedFilePath: String = ""

    private let client = UnixSocketClient()

    var canTranscribe: Bool {
        if case .fileSelected = state {
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

    func reset() {
        selectedFilePath = ""
        state = .idle
    }
}

struct ContentView: View {
    @StateObject private var manager = TranscriptionManager()

    var body: some View {
        VStack(spacing: 20) {
            Button("Select WAV File") {
                manager.selectFile()
            }
            .disabled({
                if case .idle = manager.state { return false }
                return true
            }())

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
                Text("Select a WAV file to transcribe")
                    .foregroundColor(.secondary)

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