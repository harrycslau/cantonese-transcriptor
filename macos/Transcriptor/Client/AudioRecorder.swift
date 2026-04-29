import AVFoundation

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case setupFailed
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access denied. Please enable in System Settings."
        case .setupFailed: return "Failed to set up audio recording."
        case .recordingFailed: return "Recording failed."
        }
    }
}

class AudioRecorder {
    private var audioRecorder: AVAudioRecorder?
    private(set) var currentFilePath: String?

    func requestPermissionAndRecord() async throws {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        guard granted else {
            throw AudioRecorderError.permissionDenied
        }

        try startRecording()
    }

    private func startRecording() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recording_\(Int(Date().timeIntervalSince1970)).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        guard audioRecorder?.record() == true else {
            throw AudioRecorderError.recordingFailed
        }
        currentFilePath = url.path
    }

    func stopRecording() -> String? {
        audioRecorder?.stop()
        audioRecorder = nil
        return currentFilePath
    }
}