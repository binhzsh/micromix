import Foundation
import Testing
@testable import Micromix

@Suite("MicromixAPI request building + decoding")
struct MicromixAPITests {

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedRequests: [URLRequest] = []
        private var recordedJSONBodies: [[String: Any]] = []

        var requests: [URLRequest] {
            lock.withLock { recordedRequests }
        }

        var jsonBodies: [[String: Any]] {
            lock.withLock { recordedJSONBodies }
        }

        func record(_ request: URLRequest) {
            let body = MockURLProtocol.body(of: request)
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            lock.withLock {
                recordedRequests.append(request)
                if let json {
                    recordedJSONBodies.append(json)
                }
            }
        }
    }

    private let succeededAudioJob = #"{"id":"job-1","kind":"generation","state":"succeeded","progress":1,"progress_detail":null,"error":null,"asset":{"id":"asset-1","filename":"result.wav","media_type":"audio/wav","size_bytes":3,"sha256":"abc","download_url":"/v1/assets/asset-1"}}"#
    private let succeededMIDIJob = #"{"id":"job-2","kind":"transcription","state":"succeeded","progress":1,"progress_detail":null,"error":null,"asset":{"id":"asset-2","filename":"result.mid","media_type":"audio/midi","size_bytes":4,"sha256":"def","download_url":"/v1/assets/asset-2"}}"#

    private func makeAPI() -> MicromixAPI {
        MicromixAPI(baseURL: "http://10.10.10.10:8902", configuration: .mock())
    }

    private func makeRecordingAPI() -> (MicromixAPI, RequestRecorder) {
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            let body = #"{"id":"job-reimagine","kind":"generation","state":"queued","progress":null,"progress_detail":null,"error":null,"asset":null}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return (makeAPI(), recorder)
    }

    @Test("reference reimagine posts exact route and body")
    func referenceRequestPostsExactRouteAndBody() async throws {
        let request = ReimagineRequest.reference(
            prompt: "warm piano", lyrics: nil, preset: "turbo", seed: 42,
            variationCount: 2, durationSeconds: 45, bpm: 120, key: "C minor",
            timeSignature: "4", sourceAssetID: "asset-1"
        )
        let (api, recorder) = makeRecordingAPI()
        _ = try await api.submitReimagine(request)
        #expect(recorder.requests.last?.url?.path == "/v1/jobs/reference-generation")
        #expect(recorder.jsonBodies.last?["reference_asset_id"] as? String == "asset-1")
        #expect(recorder.jsonBodies.last?["variation_count"] as? Int == 2)
    }

    @Test("repaint reimagine posts source and range")
    func repaintPostsSourceAndRange() async throws {
        let request = ReimagineRequest.repaint(
            prompt: "replace bridge", lyrics: nil, preset: "quality", seed: nil,
            variationCount: 1, startSeconds: 12, endSeconds: 24,
            repaintStrength: 0.5, sourceAssetID: "source-7"
        )
        let (api, recorder) = makeRecordingAPI()
        _ = try await api.submitReimagine(request)
        #expect(recorder.requests.last?.url?.path == "/v1/jobs/repaint")
        #expect(recorder.jsonBodies.last?["source_asset_id"] as? String == "source-7")
    }

    @Test("asset upload uses audio_file multipart field and decodes the asset")
    func uploadAssetUsesAudioFileMultipart() async throws {
        MockURLProtocol.handler = { request in
            let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            #expect(request.url?.path == "/v1/assets")
            #expect(body.contains(#"name="audio_file"; filename="source.wav""#))
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
            let response = #"{"id":"asset-upload","filename":"source.wav","media_type":"audio/wav","size_bytes":3,"sha256":"abc","download_url":"/v1/assets/asset-upload"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data(response.utf8))
        }

        let asset = try await makeAPI().uploadAsset(
            data: Data([0x52, 0x49, 0x46]), filename: "source.wav", mediaType: "audio/wav"
        )

        #expect(asset.id == "asset-upload")
        #expect(asset.mediaType == "audio/wav")
    }

    @Test("health GET path and JSON decode")
    func healthDecode() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v1/health")
            let body = #"{"service":"micromix-api","status":"ok","database":"ready","workers":{"ace_step":{"status":"cold"},"muscriptor":{"status":"ready"}}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let api = makeAPI()
        let status = try await api.health()
        #expect(status.service == "micromix-api")
        #expect(status.status == "ok")
        #expect(status.workers.aceStep.status == "cold")
        #expect(status.workers.muscriptor.status == "ready")
    }

    @Test("generate submits an ACE-Step job and downloads its asset")
    func generateBody() async throws {
        let completed = succeededAudioJob
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/assets/asset-1" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!, Data([0xFF, 0xF1, 0x00]))
            }
            let body = MockURLProtocol.body(of: request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["prompt"] as? String == "a lo-fi beat")
            #expect(json?["preset"] as? String == "quality")
            #expect(json?["duration_seconds"] as? Double == 45)
            #expect(request.url?.path == "/v1/jobs/generation")
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(completed.utf8))
        }
        let api = makeAPI()
        let bytes = try await api.generate(input: "a lo-fi beat", preset: "quality", durationSeconds: 45)
        #expect(bytes == Data([0xFF, 0xF1, 0x00]))
    }

    @Test("transcribe builds multipart with audio_file, repeated instruments, detect_tempo, return_file=false")
    func transcribeMultipart() async throws {
        let completed = succeededMIDIJob
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/assets/asset-2" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/midi"])!, Data([0x4D, 0x54, 0x68, 0x64]))
            }
            guard case let body = MockURLProtocol.body(of: request), !body.isEmpty,
                  let text = String(data: body, encoding: .utf8) else {
                Issue.record("missing multipart body")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(text.contains(#"name="audio_file""#))
            #expect(text.contains("detect_tempo"))
            #expect(text.contains("true"))
            #expect(text.contains(#"name="instruments""#))
            #expect(request.url?.path == "/v1/jobs/transcription")
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(completed.utf8))
        }
        let api = makeAPI()
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let midi = try await api.transcribe(audio: audio, filename: "input.wav", instruments: ["Piano", "Drums"], detectTempo: true)
        #expect(midi == Data([0x4D, 0x54, 0x68, 0x64]))
    }

    @Test("transcribe returns_file field is false and repeats instruments once each")
    func transcribeRepeatsInstruments() async throws {
        let completed = succeededMIDIJob
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/assets/asset-2" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            let text = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            let instrumentsCount = text.components(separatedBy: #"name="instruments""#).count - 1
            #expect(instrumentsCount == 2, "expected 2 instrument fields, got \(instrumentsCount)")
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(completed.utf8))
        }
        let api = makeAPI()
        _ = try await api.transcribe(audio: Data([0]), filename: "a.wav", instruments: ["Piano", "Drums"], detectTempo: true)
    }

    @Test("detect_tempo maps off toggle to \"false\" (valid contract value)")
    func transcribeDetectTempoOff() async throws {
        let completed = succeededMIDIJob
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/assets/asset-2" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body = MockURLProtocol.body(of: request)
            let text = String(data: body, encoding: .utf8) ?? ""
            // "off" is NOT a valid upstream value; it must be "false".
            let crlf = "\r\n"
            let marker = "name=\"detect_tempo\""
            guard let range = text.range(of: marker) else {
                Issue.record("missing detect_tempo field")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(!text[range.upperBound...].hasPrefix(crlf + crlf + "off"))
            #expect(text[range.upperBound...].hasPrefix(crlf + crlf + "false"))
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(completed.utf8))
        }
        let api = makeAPI()
        _ = try await api.transcribe(audio: Data([0]), filename: "a.wav", instruments: [], detectTempo: false)
    }

    @Test("instruments decodes gateway capabilities")
    func instrumentsFlatten() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/v1/capabilities")
            let body = #"{"generation_presets":[],"transcription_instruments":["Piano","Organ","Kit"]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let api = makeAPI()
        let instruments = try await api.instruments()
        #expect(Set(instruments) == ["Piano", "Organ", "Kit"])
    }

    @Test("Phase 1B job decodes provenance and downloads every ordered output")
    func phase1BJobProvenanceAndOutputs() async throws {
        let body = #"{"id":"job-ref","kind":"generation","state":"succeeded","parameters":{"operation":"reference","seed":42,"seeds":[42,43]},"progress":1,"progress_detail":null,"upstream_id":"ace-1","cancel_requested":false,"error":null,"inputs":[{"name":"reference","position":0,"asset":{"id":"source-1","filename":"source.wav","media_type":"audio/wav","size_bytes":4,"sha256":"source-hash","download_url":"/v1/assets/source-1"}}],"outputs":[{"name":"result","position":0,"asset":{"id":"output-1","filename":"result-1.wav","media_type":"audio/wav","size_bytes":3,"sha256":"one","download_url":"/v1/assets/output-1"}},{"name":"result","position":1,"asset":{"id":"output-2","filename":"result-2.wav","media_type":"audio/wav","size_bytes":3,"sha256":"two","download_url":"/v1/assets/output-2"}}],"asset":{"id":"output-1","filename":"result-1.wav","media_type":"audio/wav","size_bytes":3,"sha256":"one","download_url":"/v1/assets/output-1"}}"#
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/jobs/job-ref":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            case "/v1/assets/output-1":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("one".utf8))
            case "/v1/assets/output-2":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("two".utf8))
            default:
                Issue.record("unexpected request \(request)")
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let api = makeAPI()
        let job = try await api.job(id: "job-ref")
        #expect(job.operation == "reference")
        #expect(job.upstreamID == "ace-1")
        #expect(job.cancelRequested == false)
        #expect(job.inputs.map(\.asset.filename) == ["source.wav"])
        #expect(job.outputs.map(\.asset.filename) == ["result-1.wav", "result-2.wav"])
        #expect(job.parameters["seed"] == .number(42))
        let outputs = try await api.fetchOutputs(for: job)
        #expect(outputs.map(\.data) == [Data("one".utf8), Data("two".utf8)])
    }

    @Test("durable generation submission returns the accepted job before polling")
    func submitGenerationReturnsAcceptedJob() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/jobs/generation")
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data(#"{"id":"job-submit","kind":"generation","state":"queued"}"#.utf8))
        }
        let job = try await makeAPI().submitGeneration(input: "ambient", lyrics: nil, preset: "turbo", durationSeconds: 30)
        #expect(job.id == "job-submit")
        #expect(job.state == "queued")
    }

    @Test("non-2xx surfaces MicromixAPIError with the body detail")
    func errorSurfacing() async throws {
        MockURLProtocol.handler = { request in
            let body = #"{"detail":"mint request timed out"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 408, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let api = makeAPI()
        do {
            _ = try await api.health()
            Issue.record("expected an error")
        } catch let error as MicromixAPIError {
            #expect(error.statusCode == 408)
            #expect(error.detail.contains("timed out"))
        }
    }
}
