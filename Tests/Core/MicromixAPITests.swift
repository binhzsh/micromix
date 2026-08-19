import Foundation
import Testing
@testable import Micromix

@Suite("MicromixAPI request building + decoding")
struct MicromixAPITests {

    private func makeAPI() -> MicromixAPI {
        MicromixAPI(baseURL: "http://localhost:8902", configuration: .mock())
    }

    @Test("health GET path and JSON decode")
    func healthDecode() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/health")
            let body = #"{"service":"micromix-api","status":"ok","minimax":"ok","muscriptor":"unreachable"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let api = makeAPI()
        let status = try await api.health()
        #expect(status.service == "micromix-api")
        #expect(status.status == "ok")
        #expect(status.minimax == "ok")
        #expect(status.muscriptor == "unreachable")
    }

    @Test("generate POSTs JSON with input, wav format, and NO stream")
    func generateBody() async throws {
        MockURLProtocol.handler = { request in
            let body = MockURLProtocol.body(of: request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["input"] as? String == "a lo-fi beat")
            #expect(json?["response_format"] as? String == "wav")
            #expect(json?["model"] as? String == "MiniMaxAI/MiniMax-Music3")
            #expect(json?["stream"] == nil, "stream key must be absent")
            #expect(request.url?.path == "/v1/audio/speech")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!, Data([0xFF, 0xF1, 0x00]))
        }
        let api = makeAPI()
        let bytes = try await api.generate(input: "a lo-fi beat", model: "MiniMaxAI/MiniMax-Music3", responseFormat: "wav")
        #expect(bytes == Data([0xFF, 0xF1, 0x00]))
    }

    @Test("transcribe builds multipart with audio_file, repeated instruments, detect_tempo, return_file=false")
    func transcribeMultipart() async throws {
        MockURLProtocol.handler = { request in
            guard case let body = MockURLProtocol.body(of: request), !body.isEmpty,
                  let text = String(data: body, encoding: .utf8) else {
                Issue.record("missing multipart body")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(text.contains(#"name="audio_file""#))
            #expect(text.contains("detect_tempo"))
            #expect(text.contains("best-effort"))
            #expect(text.contains("return_file"))
            #expect(text.contains("false"))
            #expect(text.contains(#"name="instruments""#))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/midi"])!, Data([0x4D, 0x54, 0x68, 0x64]))
        }
        let api = makeAPI()
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let midi = try await api.transcribe(audio: audio, filename: "input.wav", instruments: ["Piano", "Drums"], detectTempo: true)
        #expect(midi == Data([0x4D, 0x54, 0x68, 0x64]))
    }

    @Test("transcribe returns_file field is false and repeats instruments once each")
    func transcribeRepeatsInstruments() async throws {
        MockURLProtocol.handler = { request in
            let text = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
            let instrumentsCount = text.components(separatedBy: #"name="instruments""#).count - 1
            #expect(instrumentsCount == 2, "expected 2 instrument fields, got \(instrumentsCount)")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let api = makeAPI()
        _ = try await api.transcribe(audio: Data([0]), filename: "a.wav", instruments: ["Piano", "Drums"], detectTempo: true)
    }

    @Test("instruments flattens grouped dict into a single list")
    func instrumentsFlatten() async throws {
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/instruments")
            let body = #"{"Keys":["Piano","Organ"],"Drums":["Kit"]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let api = makeAPI()
        let instruments = try await api.instruments()
        #expect(Set(instruments) == ["Piano", "Organ", "Kit"])
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
