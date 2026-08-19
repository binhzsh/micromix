import Foundation

/// Errors surfaced by `MicromixAPI`, carrying the HTTP status and a short detail.
struct MicromixAPIError: LocalizedError, Equatable, Sendable {
    let statusCode: Int
    let detail: String

    var errorDescription: String? {
        "HTTP \(statusCode): \(detail)"
    }

    static func unreachable(_ message: String = "server unreachable") -> MicromixAPIError {
        MicromixAPIError(statusCode: -1, detail: message)
    }
}

/// Async client for the `micromix-api` shim on the configured base URL.
///
/// Designed for Swift 6 strict concurrency: an `actor` so the underlying
/// `URLSession` is isolated, with async/await methods that throw on non-2xx
/// responses. Request building is separated so tests can assert exact request
/// shapes via a stubbed `URLProtocol`.
actor MicromixAPI {
    /// Client timeout (1260 s) strictly greater than the server's 1200 s so
    /// the server's 408/503 error wins and we never return a client timeout
    /// that masks a server error.
    static let clientTimeout: TimeInterval = 1260

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: String = SettingsStore.defaultBaseURL,
         configuration: URLSessionConfiguration? = nil) {
        // Default mock-friendly session: protocolClasses injected by tests.
        let config = configuration ?? .ephemeral
        config.timeoutIntervalForRequest = Self.clientTimeout
        config.timeoutIntervalForResource = Self.clientTimeout
        self.baseURL = URL(string: baseURL) ?? URL(string: SettingsStore.defaultBaseURL)!
        self.session = URLSession(configuration: config)
    }

    // MARK: - Endpoints

    func health() async throws -> HealthStatus {
        let (data, response) = try await send(path: "/health", method: "GET")
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(HealthStatus.self, from: data)
    }

    /// Text/lyrics -> music generation. Returns raw audio bytes on success.
    func generate(input: String,
                  lyrics: String? = nil,
                  model: String = "MiniMaxAI/MiniMax-Music3",
                  responseFormat: String = "wav") async throws -> Data {
        var body: [String: Any] = ["input": input, "model": model, "response_format": responseFormat]
        if let lyrics, !lyrics.isEmpty {
            body["lyrics"] = lyrics
        }
        // Note: no `stream` key — the shim rejects stream:true.
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(path: "/v1/audio/speech", method: "POST", body: payload)
        try Self.validate(response, data: data)
        return data
    }

    /// Audio -> MIDI transcription. File field is `audio_file`; instruments
    /// are repeated form fields. Returns raw MIDI bytes (return_file=false).
    func transcribe(audio: Data,
                    filename: String,
                    instruments: [String],
                    detectTempo: Bool = true) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        let payload = Self.multipartBody(
            boundary: boundary,
            filename: filename,
            audio: audio,
            instruments: instruments,
            detectTempo: detectTempo
        )
        let (data, response) = try await send(
            path: "/transcribe/midi",
            method: "POST",
            body: payload,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        try Self.validate(response, data: data)
        return data
    }

    /// Instrument groups from the shim, flattened for the picker.
    func instruments() async throws -> [String] {
        let (data, response) = try await send(path: "/instruments", method: "GET")
        try Self.validate(response, data: data)
        let grouped = try JSONDecoder().decode([String: [String]].self, from: data)
        return grouped.values.flatMap { $0 }
    }

    /// Fetch arbitrary bytes by URL path (e.g. `/files/{filename}`).
    func fetchBytes(path: String) async throws -> Data {
        let (data, response) = try await send(path: path, method: "GET")
        try Self.validate(response, data: data)
        return data
    }

    // MARK: - Transport

    private func send(path: String,
                      method: String,
                      body: Data? = nil,
                      contentType: String? = nil) async throws -> (Data, URLResponse) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return try await session.data(for: request)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MicromixAPIError.unreachable()
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "server returned HTTP \(http.statusCode)"
            throw MicromixAPIError(statusCode: http.statusCode, detail: detail)
        }
    }

    // MARK: - Multipart

    static func multipartBody(boundary: String,
                              filename: String,
                              audio: Data,
                              instruments: [String],
                              detectTempo: Bool) -> Data {
        var body = Data()
        func appendPart(name: String, filename: String? = nil, contentType: String? = nil, value: Data) {
            body.appendString("--\(boundary)\r\n")
            if let filename {
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            } else {
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n")
            }
            if let contentType {
                body.appendString("Content-Type: \(contentType)\r\n")
            }
            body.appendString("\r\n")
            body.append(value)
            body.appendString("\r\n")
        }

        appendPart(
            name: "audio_file",
            filename: filename,
            contentType: "application/octet-stream",
            value: audio
        )
        for instrument in instruments {
            appendPart(name: "instruments", value: Data(instrument.utf8))
        }
        appendPart(
            name: "detect_tempo",
            value: Data((detectTempo ? "best-effort" : "off").utf8)
        )
        appendPart(name: "return_file", value: Data("false".utf8))
        body.appendString("--\(boundary)--\r\n")
        return body
    }
}

extension Data {
    mutating func appendString(_ s: String) {
        append(Data(s.utf8))
    }
}
