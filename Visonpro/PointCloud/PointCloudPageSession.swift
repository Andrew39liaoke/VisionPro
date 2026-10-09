import Foundation
import Observation

enum PointCloudPageError: LocalizedError, Equatable {
    case emptyAddress
    case invalidAddress
    case unsupportedScheme

    var errorDescription: String? {
        switch self {
        case .emptyAddress:
            "请填写点云网页地址。"
        case .invalidAddress:
            "点云网页地址无效，请填写完整的主机名或 IP 地址。"
        case .unsupportedScheme:
            "点云网页地址必须使用 http 或 https。"
        }
    }
}

@MainActor
@Observable
final class PointCloudPageSession {
    private static let configuredURLKey = "pointCloudPageURL"
    private static let defaultURL = "http://192.168.3.21:8080/"

    private(set) var pageURL: URL?
    private(set) var reloadID = UUID()
    var endpointText: String

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.configuredURLKey) ?? Self.defaultURL
        endpointText = stored
        pageURL = try? Self.pageURL(from: stored)
    }

    static func pageURL(from text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PointCloudPageError.emptyAddress }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              components.host?.isEmpty == false else {
            throw PointCloudPageError.invalidAddress
        }
        guard scheme == "http" || scheme == "https" else {
            throw PointCloudPageError.unsupportedScheme
        }
        components.scheme = scheme
        guard let url = components.url else { throw PointCloudPageError.invalidAddress }
        return url
    }

    func apply(url: URL) {
        endpointText = url.absoluteString
        pageURL = url
        defaults.set(endpointText, forKey: Self.configuredURLKey)
        reloadID = UUID()
    }

    func reload() {
        reloadID = UUID()
    }
}
