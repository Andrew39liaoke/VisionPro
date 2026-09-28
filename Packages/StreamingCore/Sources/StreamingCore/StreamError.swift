import Foundation

public enum StreamError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case authentication
    case http(Int)
    case invalidResponse(String)
    case negotiation
    case network
    case mediaTimeout
    case iceFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入完整的 HTTP(S) WHEP 地址，以 /whep 结尾，且不要在地址中包含凭据。"
        case .authentication: "鉴权失败，请检查用户名、密码或 Token。"
        case .http(404): "视频流尚未发布，或路径不正确。请检查 d435i 推流程序。"
        case .http(let code): "视频服务器返回 HTTP \(code)。请检查服务器配置。"
        case .invalidResponse(let reason): "WHEP 响应无效：\(reason)"
        case .negotiation: "视频协商失败，请确认视频为 H.264 Baseline，且未启用 B 帧。"
        case .network: "无法连接视频主机，请检查地址、Wi-Fi 和系统设置中的本地网络权限。"
        case .mediaTimeout: "未收到新的视频帧，请检查推流程序、UDP 8189 和网关公布的 IP 地址。"
        case .iceFailed: "媒体连接已中断，请检查网络和 Ubuntu 的 UDP 8189 端口。"
        }
    }

    public var retryLimit: Int? {
        switch self {
        case .invalidURL, .authentication: 0
        case .invalidResponse, .negotiation: 3
        case .http(let code) where (400..<500).contains(code) && code != 404 && code != 429: 3
        default: nil
        }
    }

    public static func classify(_ error: Error) -> StreamError {
        if let error = error as? StreamError { return error }
        return .network
    }
}

public struct StreamEndpoint: Sendable, Equatable {
    public let url: URL

    public init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.query == nil, // Credentials belong in headers, never persisted URLs.
              parts.path.hasSuffix("/whep"),
              let url = parts.url else { throw StreamError.invalidURL }
        self.url = url
    }

    public var previewURL: URL {
        var parts = URLComponents(url: url.deletingLastPathComponent(), resolvingAgainstBaseURL: false)!
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        parts.queryItems = ["controls": "true", "muted": "true", "autoplay": "true", "playsinline": "true"]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }

    public func resolveSession(_ location: String) throws -> URL {
        guard !location.isEmpty, let resolved = URL(string: location, relativeTo: url)?.absoluteURL,
              resolved.scheme == url.scheme, resolved.host == url.host,
              (resolved.port ?? (resolved.scheme == "https" ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80)),
              resolved.user == nil, resolved.password == nil, resolved.fragment == nil else {
            throw StreamError.invalidResponse("会话地址缺失或跨越服务器来源")
        }
        return resolved
    }
}

public enum StreamCredential: Codable, Sendable, Equatable {
    case none
    case basic(username: String, password: String)
    case bearer(String)

    public var authorization: String? {
        switch self {
        case .none: nil
        case .basic(let username, let password): "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case .bearer(let token): "Bearer \(token)"
        }
    }
}

public struct RetryPolicy: Sendable {
    public private(set) var failures = 0
    public init() {}
    public mutating func reset() { failures = 0 }
    public mutating func nextDelay(for error: StreamError, jitter: Double = .random(in: 0.8...1.2)) -> Double? {
        if let limit = error.retryLimit, failures >= limit { return nil }
        let delay = min(pow(2, Double(min(failures, 4))), 10) * min(max(jitter, 0.8), 1.2)
        failures += 1
        return delay
    }
}
