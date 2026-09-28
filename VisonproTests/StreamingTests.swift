import XCTest
import StreamingCore
@preconcurrency import LiveKitWebRTC
@testable import Visonpro

@MainActor
final class StreamingTests: XCTestCase {
    func testNativeOfferIsReceiveOnlyH264Video() async throws {
        let engine = NativeWebRTCEngine()
        defer { engine.close() }
        try engine.prepare(servers: [])
        let offer = try await engine.makeOffer()
        XCTAssertTrue(offer.contains("m=video "))
        XCTAssertTrue(offer.contains("H264/90000"))
        XCTAssertTrue(offer.contains("a=recvonly"))
        XCTAssertFalse(offer.contains("m=audio "))
        XCTAssertFalse(offer.contains("m=application "))
    }

    func testDisconnectDuringOfferIgnoresLateCompletion() async throws {
        let engine = SuspendedEngine()
        let reachedOffer = expectation(description: "offer started")
        engine.startedOffer = { reachedOffer.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OptionsHTTP.self]
        let client = WHEPClient(engine: engine, http: WHEPHTTPClient(configuration: configuration))
        let task = Task {
            try await client.connect(endpoint: StreamEndpoint("http://test.local/d435i/whep"), credential: .none)
        }
        await fulfillment(of: [reachedOffer], timeout: 5)
        client.close()
        client.close()
        engine.completeOffer()
        do { try await task.value; XCTFail("Closed client continued negotiation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(engine.closeCount, 1)
        XCTAssertFalse(engine.acceptedAnswer)
    }

    func testFrameMailboxRetainsOnlyLatestAndStopsAfterClose() {
        let mailbox = VideoFrameMailbox(onFrame: {})
        let buffer = LKRTCI420Buffer(width: 16, height: 16)
        let first = LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1)
        let last = LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 2)
        mailbox.renderFrame(first)
        mailbox.renderFrame(last)
        XCTAssertEqual(mailbox.snapshot()?.timeStampNs, 2)
        mailbox.clear()
        mailbox.renderFrame(first)
        XCTAssertNil(mailbox.snapshot())
    }
}

@MainActor private final class SuspendedEngine: WebRTCEngine {
    var onEvent: ((EngineEvent) -> Void)?
    var startedOffer: (() -> Void)?
    var continuation: CheckedContinuation<String, Never>?
    var closeCount = 0
    var acceptedAnswer = false
    func prepare(servers: [ICEServer]) throws {}
    func makeOffer() async throws -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedOffer?()
        }
    }
    func completeOffer() { continuation?.resume(returning: "v=0\r\n"); continuation = nil }
    func acceptAnswer(_ sdp: String) async throws { acceptedAnswer = true }
    func statistics() async -> VideoSample? { nil }
    func close() { closeCount += 1 }
}

private final class OptionsHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let status = request.httpMethod == "OPTIONS" ? 204 : 500
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
