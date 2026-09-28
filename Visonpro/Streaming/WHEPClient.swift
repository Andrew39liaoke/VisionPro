import Foundation
import StreamingCore
import OSLog

@MainActor
final class WHEPClient {
    enum Event {
        case state(StreamState), track(RemoteVideoTrack), frame, metrics(StreamMetrics), failure(StreamError)
    }
    var onEvent: ((Event) -> Void)?
    private let http: WHEPHTTPClient
    private let engine: any WebRTCEngine
    private var resource: URL?
    private var credential: StreamCredential = .none
    private var offerSDP = ""
    private var candidates: [ICECandidate] = []
    private var candidateTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var negotiationTimeout: Task<Void, Never>?
    private var started = false
    private var closed = false
    private var lastFrame: ContinuousClock.Instant?
    private var calculator = MetricsCalculator()
    private let logger = Logger(subsystem: "com.liaoke.Visonpro", category: "WHEP")

    init(engine: (any WebRTCEngine)? = nil, http: WHEPHTTPClient = WHEPHTTPClient()) {
        self.engine = engine ?? NativeWebRTCEngine()
        self.http = http
    }

    func connect(endpoint: StreamEndpoint, credential: StreamCredential) async throws {
        guard !started, !closed else { throw CancellationError() }
        started = true
        self.credential = credential
        negotiationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.fail(.network)
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        let servers = try await http.iceServers(endpoint: endpoint, credential: credential)
        try ensureActive()
        onEvent?(.state(.negotiating))
        try engine.prepare(servers: servers)
        offerSDP = try await engine.makeOffer()
        try ensureActive()
        logger.info("Sending receive-only video offer")
        let answer = try await http.offer(offerSDP, endpoint: endpoint, credential: credential)
        // A response can race a disconnect. Always reclaim a resource we learned about.
        if closed || Task.isCancelled {
            Task { [http] in await http.delete(answer.resource, credential: credential) }
            throw CancellationError()
        }
        resource = answer.resource
        try await engine.acceptAnswer(answer.sdp)
        try ensureActive()
        onEvent?(.state(.connecting))
        negotiationTimeout?.cancel(); negotiationTimeout = nil
        flushCandidates()
        startMonitor()
    }

    func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        candidateTask?.cancel(); candidateTask = nil
        monitorTask?.cancel(); monitorTask = nil
        negotiationTimeout?.cancel(); negotiationTimeout = nil
        candidates.removeAll()
        engine.onEvent = nil
        engine.close()
        if let resource {
            let credential = credential
            Task { [http] in await http.delete(resource, credential: credential) }
        }
        resource = nil
    }

    private func ensureActive() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }

    private func handle(_ event: EngineEvent) {
        guard !closed else { return }
        switch event {
        case .candidate(let candidate):
            guard candidates.count < 256 else { fail(.negotiation); return }
            candidates.append(candidate)
            flushCandidates()
        case .track(let track): onEvent?(.track(track))
        case .frame:
            lastFrame = .now
            onEvent?(.frame)
        case .failure(let error): fail(error)
        }
    }

    private func flushCandidates() {
        guard candidateTask == nil, resource != nil, !candidates.isEmpty, !closed else { return }
        candidateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.candidateTask = nil }
            do {
                while !self.candidates.isEmpty, let resource = self.resource {
                    try self.ensureActive()
                    let batch = self.candidates
                    self.candidates.removeAll()
                    let fragment = try SDPFragmentBuilder.build(offer: self.offerSDP, candidates: batch)
                    try await self.http.candidates(fragment, resource: resource, credential: self.credential)
                }
            } catch {
                guard !Task.isCancelled, !self.closed else { return }
                self.fail(StreamError.classify(error))
            }
        }
    }

    private func startMonitor() {
        let connectedAt = ContinuousClock.now
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.closed else { return }
                // Probe events come from decoded frames, independent of stats availability.
                let age = (self.lastFrame ?? connectedAt).duration(to: .now)
                if age > .seconds(5) { self.fail(.mediaTimeout); return }
                if let sample = await self.engine.statistics(), !self.closed {
                    self.onEvent?(.metrics(self.calculator.update(sample)))
                }
            }
        }
    }

    private func fail(_ error: StreamError) {
        guard !closed else { return }
        let callback = onEvent
        close()
        callback?(.failure(error))
    }
}
