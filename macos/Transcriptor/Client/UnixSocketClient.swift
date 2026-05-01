import Foundation
import Darwin

enum SocketClientError: LocalizedError {
    case couldNotConnect
    case connectionClosed
    case connectionTimedOut
    case invalidResponse
    case helperError(String)

    var errorDescription: String? {
        switch self {
        case .couldNotConnect:
            return "Could not connect to the ASR helper. Make sure helper/server.py is running."
        case .connectionClosed:
            return "Connection to helper was closed unexpectedly."
        case .connectionTimedOut:
            return "Helper did not respond in time. Please try again."
        case .invalidResponse:
            return "Received an invalid response from helper."
        case .helperError(let message):
            return message
        }
    }
}

enum TranscriptionTimeout {
    case shortRecording  // ~120s — for PTT and manual recording
    case file           // ~7200s (2 hours) — for file transcription
}

actor UnixSocketClient {
    private let socketPath = "/tmp/cantonese-transcriptor.sock"

    func transcribe(audioPath: String, timeout: TranscriptionTimeout = .shortRecording) async throws -> TranscribeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketClientError.couldNotConnect
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, 104)  // UNIX_PATH_MAX on macOS
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { sockaddrPtr -> Int32 in
            sockaddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrTypedPtr in
                connect(fd, sockaddrTypedPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw SocketClientError.couldNotConnect
        }

        let request = TranscribeRequest(params: TranscribeParams(audio_path: audioPath))
        let encoder = JSONEncoder()
        var requestData = try encoder.encode(request)
        requestData.append(contentsOf: "\n".utf8)

        // Drain the entire buffer across multiple write calls if needed
        var written = 0
        while written < requestData.count {
            let bytes = requestData.withUnsafeBytes { ptr -> Int in
                guard let baseAddr = ptr.baseAddress else { return -1 }
                return write(fd, baseAddr.advanced(by: written), requestData.count - written)
            }
            guard bytes > 0 else {
                throw SocketClientError.connectionClosed
            }
            written += bytes
        }

        let seconds: Int
        switch timeout {
        case .shortRecording: seconds = 120
        case .file: seconds = 7200
        }
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read until newline
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 1)
        while true {
            let bytesRead = read(fd, &buffer, 1)
            if bytesRead < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SocketClientError.connectionTimedOut
                }
                break
            }
            if bytesRead == 0 {
                break
            }
            if buffer[0] == 0x0A {
                break
            }
            responseData.append(buffer[0])
        }

        guard !responseData.isEmpty else {
            throw SocketClientError.connectionClosed
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(TranscribeResponse.self, from: responseData)

        if let error = response.error {
            throw SocketClientError.helperError(error.message)
        }

        guard let result = response.result else {
            throw SocketClientError.invalidResponse
        }

        return result
    }

    func transcribeFileChunked(
        audioPath: String,
        onProgress: @escaping (ChunkProgress) -> Void
    ) async throws -> TranscribeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketClientError.couldNotConnect
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, 104)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { sockaddrPtr -> Int32 in
            sockaddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrTypedPtr in
                connect(fd, sockaddrTypedPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw SocketClientError.couldNotConnect
        }

        let request = ChunkedTranscribeRequest(params: TranscribeParams(audio_path: audioPath))
        let encoder = JSONEncoder()
        var requestData = try encoder.encode(request)
        requestData.append(contentsOf: "\n".utf8)

        var written = 0
        while written < requestData.count {
            let bytes = requestData.withUnsafeBytes { ptr -> Int in
                guard let baseAddr = ptr.baseAddress else { return -1 }
                return write(fd, baseAddr.advanced(by: written), requestData.count - written)
            }
            guard bytes > 0 else {
                throw SocketClientError.connectionClosed
            }
            written += bytes
        }

        // Use long timeout (2hr) for chunked file transcription
        var tv = timeval(tv_sec: 7200, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SocketClientError.connectionTimedOut
                }
                break
            }
            if bytesRead == 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])

            while let newlineIndex = responseData.firstIndex(of: 0x0A) {
                let lineData = Data(responseData[..<newlineIndex])
                responseData = Data(responseData[(newlineIndex+1)...])
                guard !lineData.isEmpty else { continue }

                // Check if this is a progress notification
                if let progress = try? JSONDecoder().decode(TranscribeProgressEvent.self, from: lineData) {
                    if progress.method == "transcribe_progress" {
                        onProgress(ChunkProgress(
                            current: progress.params.chunk,
                            total: progress.params.total,
                            stage: progress.params.stage
                        ))
                        continue
                    }
                }

                // Otherwise decode as final response
                if let finalResponse = try? JSONDecoder().decode(TranscribeResponse.self, from: lineData) {
                    if let error = finalResponse.error {
                        throw SocketClientError.helperError(error.message)
                    }
                    guard let result = finalResponse.result else {
                        throw SocketClientError.invalidResponse
                    }
                    return result
                }
            }
        }
        throw SocketClientError.connectionClosed
    }

    func transcribeWithDiarization(
        audioPath: String,
        numSpeakers: Int,
        onProgress: @escaping (ChunkProgress) -> Void
    ) async throws -> DiarizedTranscribeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketClientError.couldNotConnect
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, 104)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { sockaddrPtr -> Int32 in
            sockaddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrTypedPtr in
                connect(fd, sockaddrTypedPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw SocketClientError.couldNotConnect
        }

        let params = DiarizedTranscribeParams(
            audio_path: audioPath,
            job_id: UUID().uuidString,
            num_speakers: numSpeakers
        )
        let request = DiarizedTranscribeRequest(params: params)
        let encoder = JSONEncoder()
        var requestData = try encoder.encode(request)
        requestData.append(contentsOf: "\n".utf8)

        var written = 0
        while written < requestData.count {
            let bytes = requestData.withUnsafeBytes { ptr -> Int in
                guard let baseAddr = ptr.baseAddress else { return -1 }
                return write(fd, baseAddr.advanced(by: written), requestData.count - written)
            }
            guard bytes > 0 else {
                throw SocketClientError.connectionClosed
            }
            written += bytes
        }

        // Use long timeout (2hr) for diarized file transcription
        var tv = timeval(tv_sec: 7200, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SocketClientError.connectionTimedOut
                }
                break
            }
            if bytesRead == 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])

            while let newlineIndex = responseData.firstIndex(of: 0x0A) {
                let lineData = Data(responseData[..<newlineIndex])
                responseData = Data(responseData[(newlineIndex+1)...])
                guard !lineData.isEmpty else { continue }

                // Check if this is a progress notification
                if let progress = try? JSONDecoder().decode(TranscribeProgressEvent.self, from: lineData) {
                    if progress.method == "transcribe_progress" {
                        onProgress(ChunkProgress(
                            current: progress.params.chunk,
                            total: progress.params.total,
                            stage: progress.params.stage
                        ))
                        continue
                    }
                }

                // Otherwise decode as final response
                if let finalResponse = try? JSONDecoder().decode(DiarizedTranscribeResponse.self, from: lineData) {
                    if let error = finalResponse.error {
                        throw SocketClientError.helperError(error.message)
                    }
                    guard let result = finalResponse.result else {
                        throw SocketClientError.invalidResponse
                    }
                    return result
                }
            }
        }
        throw SocketClientError.connectionClosed
    }

    func ping() async throws -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, 104)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { sockaddrPtr -> Int32 in
            sockaddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrTypedPtr in
                connect(fd, sockaddrTypedPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return false }

        let request = PingRequest()
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(contentsOf: "\n".utf8)

        var written = 0
        while written < data.count {
            let bytes = data.withUnsafeBytes { ptr -> Int in
                guard let baseAddr = ptr.baseAddress else { return -1 }
                return write(fd, baseAddr.advanced(by: written), data.count - written)
            }
            guard bytes > 0 else { return false }
            written += bytes
        }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 1)
        while true {
            let bytesRead = read(fd, &buffer, 1)
            if bytesRead <= 0 { break }
            if buffer[0] == 0x0A { break }
            responseData.append(buffer[0])
        }

        guard !responseData.isEmpty else { return false }
        let decoder = JSONDecoder()
        let response = try? decoder.decode(PingResponse.self, from: responseData)
        return response?.result?.status == "ok"
    }
}