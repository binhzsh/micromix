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
    static let clientTimeout: TimeInterval = 120

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
        let (data, response) = try await send(path: "/v1/health", method: "GET")
        try Self.validate(response, data: data)
        return try Self.decoder.decode(HealthStatus.self, from: data)
    }

    func capabilities() async throws -> Capabilities {
        let (data, response) = try await send(path: "/v1/capabilities", method: "GET")
        try Self.validate(response, data: data)
        return try Self.decoder.decode(Capabilities.self, from: data)
    }

    /// Submit a durable ACE-Step job, poll it, and download its resulting asset.
    func generate(input: String,
                  lyrics: String? = nil,
                  preset: String = "turbo",
                  durationSeconds: Double = 30) async throws -> Data {
        let job = try await submitGeneration(
            input: input, lyrics: lyrics, preset: preset, durationSeconds: durationSeconds
        )
        return try await awaitAsset(for: job)
    }

    /// Submit generation and return as soon as the gateway accepts its durable job.
    func submitGeneration(
        input: String,
        lyrics: String? = nil,
        preset: String = "turbo",
        durationSeconds: Double = 30
    ) async throws -> RemoteJob {
        var body: [String: Any] = [
            "prompt": input,
            "preset": preset,
            "duration_seconds": durationSeconds,
        ]
        if let lyrics, !lyrics.isEmpty {
            body["lyrics"] = lyrics
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await submitJob(path: "/v1/jobs/generation", body: payload)
    }

    /// Audio -> MIDI transcription. File field is `audio_file`; instruments
    /// are repeated form fields. Returns the downloaded MIDI asset bytes.
    func transcribe(audio: Data,
                    filename: String,
                    instruments: [String],
                    detectTempo: Bool = true) async throws -> Data {
        let job = try await submitTranscription(
            audio: audio, filename: filename, instruments: instruments, detectTempo: detectTempo
        )
        return try await awaitAsset(for: job)
    }

    /// Submit transcription and return as soon as the gateway accepts its durable job.
    func submitTranscription(
        audio: Data,
        filename: String,
        instruments: [String],
        detectTempo: Bool = true
    ) async throws -> RemoteJob {
        let boundary = "Boundary-\(UUID().uuidString)"
        let payload = Self.multipartBody(
            boundary: boundary,
            filename: filename,
            audio: audio,
            instruments: instruments,
            detectTempo: detectTempo
        )
        return try await submitJob(
            path: "/v1/jobs/transcription",
            body: payload,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    func jobs() async throws -> [RemoteJob] {
        let (data, response) = try await send(path: "/v1/jobs", method: "GET")
        try Self.validate(response, data: data)
        return try Self.decoder.decode([RemoteJob].self, from: data)
    }

    func job(id: String) async throws -> RemoteJob {
        let (data, response) = try await send(path: "/v1/jobs/\(id)", method: "GET")
        try Self.validate(response, data: data)
        return try Self.decoder.decode(RemoteJob.self, from: data)
    }

    func fetchOutputs(for job: RemoteJob) async throws -> [DownloadedRemoteAsset] {
        guard job.state == "succeeded" else {
            throw MicromixAPIError(statusCode: 500, detail: job.error ?? "job \(job.state)")
        }
        let assets = job.outputs.isEmpty ? (job.asset.map { [$0] } ?? []) : job.outputs.map(\.asset)
        return try await assets.asyncMap { asset in
            DownloadedRemoteAsset(asset: asset, data: try await fetchBytes(path: asset.downloadUrl))
        }
    }

    private func submitJob(path: String,
                           body: Data,
                           contentType: String = "application/json") async throws -> RemoteJob {
        let (data, response) = try await send(
            path: path,
            method: "POST",
            body: body,
            contentType: contentType
        )
        try Self.validate(response, data: data)
        return try Self.decoder.decode(RemoteJob.self, from: data)
    }

    private func awaitAsset(for submitted: RemoteJob) async throws -> Data {
        do {
            var job = submitted
            while !job.isTerminal {
                try await Task.sleep(for: .seconds(1))
                job = try await self.job(id: job.id)
            }
            guard job.state == "succeeded", let asset = job.asset else {
                throw MicromixAPIError(
                    statusCode: job.state == "cancelled" ? 499 : 500,
                    detail: job.error ?? "job \(job.state)"
                )
            }
            return try await fetchBytes(path: asset.downloadUrl)
        } catch is CancellationError {
            try? await cancel(jobID: submitted.id)
            throw CancellationError()
        }
    }

    func cancel(jobID: String) async throws {
        let (data, response) = try await send(path: "/v1/jobs/\(jobID)/cancel", method: "POST")
        try Self.validate(response, data: data)
    }

    /// Instrument groups from the shim, flattened for the picker.
    func instruments() async throws -> [String] {
        try await capabilities().transcriptionInstruments
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
        appendPart(name: "detect_tempo", value: Data((detectTempo ? "true" : "false").utf8))
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private extension Array {
    func asyncMap<T: Sendable>(_ transform: @Sendable (Element) async throws -> T) async throws -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}

extension Data {
    mutating func appendString(_ s: String) {
        append(Data(s.utf8))
    }
}
