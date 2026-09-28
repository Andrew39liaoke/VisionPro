import SwiftUI
import Observation
import OSLog
import StreamingCore

@MainActor @Observable
final class StreamSession {
    private(set) var state: StreamState = .idle
    private(set) var errorMessage: String?
    private(set) var metrics = StreamMetrics()
    private(set) var video: RemoteVideoTrack?
    private(set) var wantsConnection = false
    private(set) var reconnectCount = 0
    var endpointText: String
    var fillVideo: Bool {
        didSet { defaults.set(fillVideo, forKey: "fillVideo") }
    }
    var showMetrics: Bool = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "com.liaoke.Visonpro", category: "Session")
    @ObservationIgnored private var client: WHEPClient?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var stableTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retryPolicy = RetryPolicy()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var credential: StreamCredential = .none

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        endpointText = defaults.string(forKey: "lastSuccessfulEndpoint") ?? defaults.string(forKey: "configuredEndpoint") ?? ""
        fillVideo = defaults.bool(forKey: "fillVideo")
    }

    func sceneChanged(_ phase: ScenePhase) {
        active = phase == .active
        if !started, active {
            started = true
            if let previous = defaults.string(forKey: "lastSuccessfulEndpoint"), !previous.isEmpty { connect() }
            return
        }
        if active, wantsConnection, client == nil { startAttempt() }
        else if !active {
            releaseAttempt()
            state = wantsConnection ? .paused : .idle
        }
    }

    func connect() {
        do {
            let endpoint = try StreamEndpoint(endpointText)
            endpointText = endpoint.url.absoluteString
            credential = try CredentialStore.load(for: endpointText)
            defaults.set(endpointText, forKey: "configuredEndpoint")
            wantsConnection = true
            retryPolicy.reset()
            reconnectCount = 0
            releaseAttempt()
            if active { startAttempt() } else { state = .paused }
        } catch {
            disconnect()
            errorMessage = error.localizedDescription
            state = .failed
        }
    }

    func disconnect() {
        wantsConnection = false
        releaseAttempt()
        state = .idle
        errorMessage = nil
    }

    func saveSettings(url: String, credential: StreamCredential, fill: Bool) throws {
        let endpoint = try StreamEndpoint(url)
        try CredentialStore.save(credential, for: endpoint.url.absoluteString)
        disconnect()
        endpointText = endpoint.url.absoluteString
        defaults.set(endpointText, forKey: "configuredEndpoint")
        // Old successful URL must not override a newly selected connection on relaunch.
        defaults.removeObject(forKey: "lastSuccessfulEndpoint")
        fillVideo = fill
        connect()
    }

    private func startAttempt() {
        guard active, wantsConnection else { return }
        releaseAttempt()
        let id = generation
        state = .requesting
        errorMessage = nil
        let client = WHEPClient()
        self.client = client
        client.onEvent = { [weak self] event in
            guard let self, self.generation == id else { return }
            switch event {
            case .state(let state):
                if self.state != .playing { self.state = state }
            case .track(let track): self.video = track
            case .frame:
                guard self.state != .playing else { return }
                self.state = .playing
                self.errorMessage = nil
                self.defaults.set(self.endpointText, forKey: "lastSuccessfulEndpoint")
                self.logger.info("Video first frame received")
                self.stableTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.generation == id, self.state == .playing else { return }
                    self.retryPolicy.reset()
                }
            case .metrics(let metrics): self.metrics = metrics
            case .failure(let error): self.handleFailure(error, generation: id)
            }
        }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try StreamEndpoint(self.endpointText)
                try await client.connect(endpoint: endpoint, credential: self.credential)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.handleFailure(StreamError.classify(error), generation: id)
            }
        }
    }

    private func handleFailure(_ error: StreamError, generation id: UUID) {
        guard generation == id, wantsConnection else { return }
        releaseAttempt()
        errorMessage = error.localizedDescription
        logger.error("Stream failure: \(error.localizedDescription, privacy: .public)")
        guard let delay = retryPolicy.nextDelay(for: error) else {
            wantsConnection = false
            state = .failed
            return
        }
        state = .retrying(seconds: Int(ceil(delay)))
        let retryID = generation
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == retryID, self.active, self.wantsConnection else { return }
            self.reconnectCount += 1
            self.startAttempt()
        }
    }

    private func releaseAttempt() {
        generation = UUID()
        connectionTask?.cancel(); connectionTask = nil
        retryTask?.cancel(); retryTask = nil
        stableTask?.cancel(); stableTask = nil
        client?.close(); client = nil
        video = nil
        metrics = StreamMetrics()
    }
}
