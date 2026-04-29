import Foundation
import AppKit
import Darwin

enum HelperState: Equatable {
    case notRunning
    case starting
    case ready
    case failed(String)
}

@MainActor
class HelperManager: ObservableObject {
    @Published var state: HelperState = .notRunning
    @Published private(set) var helperStartedByApp = false
    private var helperProcess: Process?
    private var helperStderr = ""

    init() {
        checkHelperHealth()
    }

    func checkHelperHealth() {
        Task {
            let alive = await pingHelper()
            if alive {
                state = .ready
            } else {
                state = .notRunning
            }
            if !alive {
                startHelper()
            }
        }
    }

    func startHelper() {
        guard state != .ready && state != .starting else { return }
        state = .starting
        helperStderr = ""

        guard let helperPath = resolveHelperPath() else {
            state = .failed("TRANSCRIPTOR_HELPER_PATH is not set — configure in Xcode Scheme")
            return
        }
        guard FileManager.default.fileExists(atPath: helperPath) else {
            state = .failed("Helper script not found at \(helperPath)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvePythonPath())
        process.arguments = [helperPath]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.helperStderr += output
            }
            if output.contains("ready") {
                DispatchQueue.main.async {
                    guard self?.state == .starting else { return }
                    self?.state = .ready
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleHelperTermination()
            }
        }

        helperProcess = process

        do {
            try process.run()
            helperStartedByApp = true
        } catch {
            helperProcess = nil
            state = .failed("Failed to start helper: \(error.localizedDescription)")
            helperStartedByApp = false
        }

        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self.handleStartupTimeout()
        }
    }

    func stopHelperIfOwned() {
        guard helperStartedByApp else { return }
        guard let process = helperProcess else {
            helperStartedByApp = false
            state = .notRunning
            return
        }

        process.terminate()
        if waitForExit(process, timeout: 2.0) {
            helperProcess = nil
            helperStartedByApp = false
            state = .notRunning
            return
        }

        // Still running after 2s — SIGKILL it
        kill(pid_t(process.processIdentifier), SIGKILL)
        _ = waitForExit(process, timeout: 0.5)

        if process.isRunning {
            print("Helper did not exit after SIGKILL")
        }

        helperProcess = nil
        helperStartedByApp = false
        state = .notRunning
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return !process.isRunning
    }

    private func handleHelperTermination() {
        guard helperStartedByApp else { return }
        helperStartedByApp = false
        helperProcess = nil
        if state == .starting {
            let msg = helperStderr.isEmpty == false
                ? "Helper failed: \(helperStderr)"
                : "Helper exited unexpectedly"
            state = .failed(msg)
        } else if state == .ready {
            state = .notRunning
        }
    }

    private func handleStartupTimeout() {
        if state == .starting {
            helperProcess?.terminate()
            helperProcess = nil
            let msg = helperStderr.isEmpty ? "Helper startup timed out" : "Helper failed: \(helperStderr)"
            state = .failed(msg)
            helperStartedByApp = false
        }
    }

    private func resolveHelperPath() -> String? {
        guard let envPath = getenv("TRANSCRIPTOR_HELPER_PATH") else {
            return nil
        }
        return String(cString: envPath)
    }

    private func resolvePythonPath() -> String {
        if let envPath = getenv("TRANSCRIPTOR_PYTHON") {
            return String(cString: envPath)
        }
        return "/usr/bin/python3"
    }

    private func pingHelper() async -> Bool {
        return await withCheckedContinuation { continuation in
            Task {
                let client = UnixSocketClient()
                let result = try? await client.ping()
                continuation.resume(returning: result ?? false)
            }
        }
    }
}