import Foundation
import XCTest
@testable import StreamingCore

final class StreamingCoreTests: XCTestCase {
    func testEndpointAndSessionURLs() throws {
        let endpoint = try StreamEndpoint("  http://192.168.1.10:8889/d435i/whep  ")
        XCTAssertEqual(try endpoint.resolveSession("session/123").path, "/d435i/session/123")
        XCTAssertEqual(try endpoint.resolveSession("/d435i/whep/123").path, "/d435i/whep/123")
        XCTAssertEqual(URLComponents(url: endpoint.previewURL, resolvingAgainstBaseURL: false)?.path, "/d435i/")
        XCTAssertThrowsError(try endpoint.resolveSession("https://other.test/session"))
        XCTAssertThrowsError(try endpoint.resolveSession("http://192.168.1.10:9999/session"))
        XCTAssertThrowsError(try endpoint.resolveSession(""))
        for invalid in ["rtsp://host/d435i", "http://host/d435i/", "http://u:p@host/whep", "http://host/whep?token=secret", "http://host/whep#x"] {
            XCTAssertThrowsError(try StreamEndpoint(invalid))
        }
    }

    func testICEHeadersWithQuotedDelimiters() throws {
        let result = try ICELinkParser.parse(#"<stun:stun.example:3478>; rel="ice-server", <turn:turn.example:3478?transport=tcp>; rel="ice-server"; username="u,ser"; credential="pass;\"word"; credential-type="password", <https://example.test>; rel="other""#)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].username, "u,ser")
        XCTAssertEqual(result[1].credential, "pass;\"word")
        XCTAssertEqual(try ICELinkParser.parse(nil), [])
        XCTAssertThrowsError(try ICELinkParser.parse("<https://bad.test>; rel=ice-server"))
    }

    func testSDPUsesActualMidAndMediaCredentials() throws {
        let offer = "v=0\r\na=ice-ufrag:global\r\na=ice-pwd:globalPwd\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:audio\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:video\r\na=ice-ufrag:local\r\na=ice-pwd:localPwd\r\n"
        let result = try SDPFragmentBuilder.build(offer: offer, candidates: [.init(sdp: "candidate:1 1 UDP 1 10.0.0.1 5000 typ host", mLineIndex: 0, mid: "video")])
        XCTAssertTrue(result.contains("m=video"))
        XCTAssertFalse(result.contains("m=audio"))
        XCTAssertTrue(result.contains("a=mid:video\r\na=ice-ufrag:local\r\na=ice-pwd:localPwd"))
        XCTAssertTrue(result.hasSuffix("\r\n"))
        let audio = try SDPFragmentBuilder.build(offer: offer, candidates: [.init(sdp: "candidate:2 1 UDP 1 10.0.0.1 5000 typ host", mLineIndex: 0, mid: nil)])
        XCTAssertTrue(audio.contains("a=ice-ufrag:global"))
        XCTAssertThrowsError(try SDPFragmentBuilder.build(offer: offer, candidates: [.init(sdp: "candidate:x\r\na=bad", mLineIndex: 0, mid: nil)]))
        XCTAssertThrowsError(try SDPFragmentBuilder.build(offer: offer, candidates: [.init(sdp: "candidate:x", mLineIndex: 5, mid: nil)]))
    }

    func testRetryPolicyLimitsAndReset() {
        var policy = RetryPolicy()
        XCTAssertNil(policy.nextDelay(for: .authentication))
        XCTAssertEqual((0..<6).map { _ in policy.nextDelay(for: .network, jitter: 1)! }, [1, 2, 4, 8, 10, 10])
        policy.reset()
        XCTAssertEqual(policy.nextDelay(for: .negotiation, jitter: 1), 1)
        XCTAssertEqual(policy.nextDelay(for: .negotiation, jitter: 1), 2)
        XCTAssertEqual(policy.nextDelay(for: .negotiation, jitter: 1), 4)
        XCTAssertNil(policy.nextDelay(for: .negotiation))
    }

    func testMetricsAreIntervalBasedAndResetForNewSSRC() throws {
        var calculator = MetricsCalculator()
        var sample = VideoSample()
        sample.streamID = "video1"; sample.timestamp = 1; sample.bytes = 1000
        sample.packets = 90; sample.decoded = 30; sample.lost = 10
        XCTAssertNil(calculator.update(sample).mbps)
        sample.timestamp = 3; sample.bytes = 1_001_000; sample.packets = 180; sample.decoded = 90; sample.lost = 20
        let metrics = calculator.update(sample)
        XCTAssertEqual(try XCTUnwrap(metrics.mbps), 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.fps), 30)
        XCTAssertEqual(try XCTUnwrap(metrics.lossPercent), 10)
        sample.streamID = "video2"; sample.timestamp = 4
        XCTAssertNil(calculator.update(sample).mbps)
    }
}

// The response is encoded in the hostname, avoiding mutable global handlers and test races.
private final class MockHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
        let host = request.url!.host!
        if host.hasPrefix("status") {
            status = Int(host.dropFirst(6).prefix(3))!
        } else if request.httpMethod == "OPTIONS" {
            status = 204
            headers["Link"] = "<stun:example.test:3478>; rel=ice-server"
        } else if request.httpMethod == "POST" {
            status = 201
            headers = ["Location": "session/123", "Content-Type": host == "malformed.test" ? "text/html" : "application/sdp"]
            body = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
        } else if request.httpMethod == "PATCH" {
            status = request.value(forHTTPHeaderField: "If-Match") == "*" && request.value(forHTTPHeaderField: "Content-Type") == "application/trickle-ice-sdpfrag" ? 204 : 400
        } else if request.httpMethod == "DELETE" { status = 204 }
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer test-token" { status = 401 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class WHEPHTTPTests: XCTestCase {
    private func makeClient() -> WHEPHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        return WHEPHTTPClient(configuration: configuration)
    }

    func testOptionsPostPatchDelete() async throws {
        let client = makeClient()
        let endpoint = try StreamEndpoint("https://stream.test/d435i/whep")
        let credential = StreamCredential.bearer("test-token")
        let servers = try await client.iceServers(endpoint: endpoint, credential: credential)
        XCTAssertEqual(servers.count, 1)
        let answer = try await client.offer("v=0", endpoint: endpoint, credential: credential)
        XCTAssertEqual(answer.resource.path, "/d435i/session/123")
        try await client.candidates("candidate", resource: answer.resource, credential: credential)
        await client.delete(answer.resource, credential: credential)
    }

    func testHTTPFailuresAndMalformedAnswer() async throws {
        for code in [200, 400, 401, 403, 404, 415, 500] {
            let endpoint = try StreamEndpoint("https://status\(code).test/d435i/whep")
            do {
                _ = try await makeClient().offer("v=0", endpoint: endpoint, credential: .bearer("test-token"))
                XCTFail("Unexpected success: \(code)")
            } catch {
                XCTAssertEqual(error as? StreamError, [401, 403].contains(code) ? .authentication : .http(code))
            }
        }
        do {
            _ = try await makeClient().offer("v=0", endpoint: StreamEndpoint("https://malformed.test/d435i/whep"), credential: .bearer("test-token"))
            XCTFail("Accepted HTML as SDP")
        } catch {
            guard case .invalidResponse = error as? StreamError else { XCTFail("Wrong error"); return }
        }
    }
}
