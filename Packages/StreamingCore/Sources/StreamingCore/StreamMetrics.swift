import Foundation

public struct VideoSample: Sendable {
    public var timestamp: Double = 0
    public var streamID: String = ""
    public var bytes: Double = 0
    public var packets: Double = 0
    public var lost: Double = 0
    public var decoded: Double = 0
    public var dropped: Double = 0
    public var width: Int = 0
    public var height: Int = 0
    public var fps: Double?
    public var jitter: Double?
    public var rtt: Double?
    public var transport: String = "—"
    public var decoder: String = "—"
    public init() {}
}

public struct StreamMetrics: Sendable {
    public var width = 0, height = 0
    public var fps: Double?
    public var mbps: Double?
    public var lossPercent: Double?
    public var jitterMS: Double?
    public var rttMS: Double?
    public var decoded = 0, dropped = 0
    public var transport = "—", decoder = "—"
    public init() {}
    public var resolution: String { width > 0 && height > 0 ? "\(width) × \(height)" : "—" }
}

public struct MetricsCalculator: Sendable {
    private var previous: VideoSample?
    public init() {}
    public mutating func update(_ sample: VideoSample) -> StreamMetrics {
        var result = StreamMetrics()
        result.width = sample.width; result.height = sample.height
        result.decoded = Int(sample.decoded); result.dropped = Int(sample.dropped)
        result.fps = sample.fps; result.jitterMS = sample.jitter.map { $0 * 1000 }; result.rttMS = sample.rtt.map { $0 * 1000 }
        result.transport = sample.transport; result.decoder = sample.decoder
        if let previous, previous.streamID == sample.streamID, sample.timestamp > previous.timestamp,
           sample.bytes >= previous.bytes, sample.decoded >= previous.decoded {
            let elapsed = sample.timestamp - previous.timestamp
            result.mbps = (sample.bytes - previous.bytes) * 8 / elapsed / 1_000_000
            result.fps = sample.fps ?? (sample.decoded - previous.decoded) / elapsed
            let received = max(0, sample.packets - previous.packets)
            let lost = max(0, sample.lost - previous.lost)
            if received + lost > 0 { result.lossPercent = lost / (received + lost) * 100 }
        }
        previous = sample
        return result
    }
}
