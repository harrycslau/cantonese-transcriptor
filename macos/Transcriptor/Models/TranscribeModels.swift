import Foundation

struct TranscribeRequest: Codable {
    let jsonrpc: String
    let method: String
    let params: TranscribeParams
    let id: Int

    enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params, id
    }

    init(params: TranscribeParams) {
        self.jsonrpc = "2.0"
        self.method = "transcribe"
        self.params = params
        self.id = 1
    }
}

struct TranscribeParams: Codable {
    let audio_path: String
    let job_id: String

    init(audio_path: String) {
        self.audio_path = audio_path
        self.job_id = UUID().uuidString
    }
}

struct TranscribeResponse: Codable {
    let jsonrpc: String
    let result: TranscribeResult?
    let error: JSONRPCError?
    let id: Int
}

struct TranscribeResult: Codable {
    let job_id: String
    let transcript: String
    let timing: TimingInfo
}

struct TimingInfo: Codable {
    let model_load_time_s: Double
    let transcribe_time_s: Double
    let audio_duration_s: Double
    let real_time_factor: Double
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
}

struct PingRequest: Codable {
    let jsonrpc: String
    let method: String
    let id: Int

    init() {
        self.jsonrpc = "2.0"
        self.method = "ping"
        self.id = 0
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, method, id
    }
}

struct PingResponse: Codable {
    let jsonrpc: String
    let result: PingResult?
    struct PingResult: Codable { let status: String }
}