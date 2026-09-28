import Foundation
import CoreGraphics
import StreamingCore
@preconcurrency import LiveKitWebRTC

@MainActor
protocol WebRTCEngine: AnyObject {
    var onEvent: ((EngineEvent) -> Void)? { get set }
    func prepare(servers: [ICEServer]) throws
    func makeOffer() async throws -> String
    func acceptAnswer(_ sdp: String) async throws
    func statistics() async -> VideoSample?
    func close()
}

enum EngineEvent {
    case candidate(ICECandidate), track(RemoteVideoTrack), frame, failure(StreamError)
}

@MainActor
final class RemoteVideoTrack {
    let track: LKRTCVideoTrack
    let frames: VideoFrameMailbox
    init(track: LKRTCVideoTrack, onFrame: @escaping @Sendable () -> Void) {
        self.track = track
        frames = VideoFrameMailbox(onFrame: onFrame)
        track.add(frames)
    }
    func detach() { track.remove(frames); frames.clear() }
}

// libwebrtc owns the frame's buffers; retaining a frame retains its pixel buffer.
// The lock protects a single latest-frame slot, never an unbounded render queue.
nonisolated final class VideoFrameMailbox: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: LKRTCVideoFrame?
    private var lastPulse = -Double.infinity
    private var stopped = false
    private let onFrame: @Sendable () -> Void
    init(onFrame: @escaping @Sendable () -> Void) { self.onFrame = onFrame }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        latest = frame
        let now = ProcessInfo.processInfo.systemUptime
        let pulse = now - lastPulse >= 0.5
        if pulse { lastPulse = now }
        lock.unlock()
        if pulse { onFrame() }
    }
    func snapshot() -> LKRTCVideoFrame? { lock.lock(); defer { lock.unlock() }; return latest }
    func clear() { lock.lock(); stopped = true; latest = nil; lock.unlock() }
}

@MainActor
final class NativeWebRTCEngine: WebRTCEngine {
    var onEvent: ((EngineEvent) -> Void)?
    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
    }()
    private var peer: LKRTCPeerConnection?
    private var delegate: PeerDelegate?
    private var remote: RemoteVideoTrack?
    private var closed = false

    func prepare(servers: [ICEServer]) throws {
        guard peer == nil, !closed else { throw StreamError.negotiation }
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.iceServers = servers.map { LKRTCIceServer(urlStrings: [$0.url], username: $0.username, credential: $0.credential) }
        let delegate = PeerDelegate { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
        self.delegate = delegate
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw StreamError.negotiation
        }
        self.peer = peer
        let setup = LKRTCRtpTransceiverInit()
        setup.direction = .recvOnly
        guard let video = peer.addTransceiver(of: .video, init: setup) else { throw StreamError.negotiation }
        let codecs = Self.factory.rtpReceiverCapabilities(forKind: "video").codecs
        let h264 = codecs.filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
        guard !h264.isEmpty else { throw StreamError.negotiation }
        // Keep RTX/FEC capabilities while moving H.264 ahead of other codecs.
        try video.setCodecPreferences(h264 + codecs.filter { $0.name.caseInsensitiveCompare("H264") != .orderedSame }, error: ())
    }

    func makeOffer() async throws -> String {
        guard let peer, !closed else { throw CancellationError() }
        let sdp: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp, error == nil { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: StreamError.negotiation) }
            }
        }
        try checkOpen()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { error in
                if error != nil { continuation.resume(throwing: StreamError.negotiation) }
                else { continuation.resume() }
            }
        }
        try checkOpen()
        return sdp.sdp
    }

    func acceptAnswer(_ sdp: String) async throws {
        guard let peer, !closed else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if error != nil { continuation.resume(throwing: StreamError.negotiation) }
                else { continuation.resume() }
            }
        }
        try checkOpen()
    }

    func statistics() async -> VideoSample? {
        guard let peer, !closed else { return nil }
        return await withCheckedContinuation { continuation in
            peer.statistics { report in continuation.resume(returning: Self.videoSample(report)) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        remote?.detach(); remote = nil
        peer?.delegate = nil
        peer?.close(); peer = nil
        delegate = nil
        onEvent = nil
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        if closed { throw CancellationError() }
    }

    private func receive(_ event: PeerEvent) {
        guard !closed else { return }
        switch event {
        case .candidate(let candidate): onEvent?(.candidate(candidate))
        case .failed: onEvent?(.failure(.iceFailed))
        case .track(let track):
            if remote?.track.trackId == track.trackId { return }
            remote?.detach()
            let video = RemoteVideoTrack(track: track) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.closed else { return }
                    self.onEvent?(.frame)
                }
            }
            remote = video
            onEvent?(.track(video))
        }
    }

    nonisolated private static func videoSample(_ report: LKRTCStatisticsReport) -> VideoSample? {
        let stats = report.statistics
        guard let inbound = stats.values.first(where: {
            $0.type == "inbound-rtp" && (($0.values["kind"] as? String ?? $0.values["mediaType"] as? String) == "video")
        }) else { return nil }
        let values = inbound.values
        func number(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
        var sample = VideoSample()
        sample.streamID = inbound.id
        sample.timestamp = inbound.timestamp_us / 1_000_000
        sample.bytes = number("bytesReceived") ?? 0
        sample.packets = number("packetsReceived") ?? 0
        sample.lost = number("packetsLost") ?? 0
        sample.decoded = number("framesDecoded") ?? 0
        sample.dropped = number("framesDropped") ?? 0
        sample.width = Int(number("frameWidth") ?? 0); sample.height = Int(number("frameHeight") ?? 0)
        sample.fps = number("framesPerSecond"); sample.jitter = number("jitter")
        sample.decoder = values["decoderImplementation"] as? String ?? "—"
        let transportID = values["transportId"] as? String
        let transport = transportID.flatMap { stats[$0] } ?? stats.values.first { $0.type == "transport" }
        if let pairID = transport?.values["selectedCandidatePairId"] as? String, let pair = stats[pairID] {
            sample.rtt = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
            if let localID = pair.values["localCandidateId"] as? String,
               let remoteID = pair.values["remoteCandidateId"] as? String {
                let local = stats[localID]?.values, remote = stats[remoteID]?.values
                let proto = local?["protocol"] as? String ?? "?"
                sample.transport = "\(proto.uppercased()) · \(local?["candidateType"] as? String ?? "?") → \(remote?["candidateType"] as? String ?? "?")"
            }
        }
        return sample
    }
}

// The SDK invokes delegates on its own signaling thread. Only immutable events
// cross to MainActor; no SwiftUI or connection-owned state is changed here.
nonisolated private enum PeerEvent: @unchecked Sendable {
    case candidate(ICECandidate), track(LKRTCVideoTrack), failed
}

nonisolated private final class PeerDelegate: NSObject, LKRTCPeerConnectionDelegate {
    let emit: @Sendable (PeerEvent) -> Void
    init(emit: @escaping @Sendable (PeerEvent) -> Void) { self.emit = emit }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        if newState == .failed { emit(.failed) }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        emit(.candidate(ICECandidate(sdp: candidate.sdp, mLineIndex: Int(candidate.sdpMLineIndex), mid: candidate.sdpMid)))
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) { dataChannel.close() }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        if newState == .failed || newState == .closed { emit(.failed) }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        if let track = rtpReceiver.track as? LKRTCVideoTrack { emit(.track(track)) }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? LKRTCVideoTrack { emit(.track(track)) }
    }
}
