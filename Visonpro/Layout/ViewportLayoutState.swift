import CoreGraphics
import Foundation
import Observation

enum PrimaryContent: String, Codable {
    case video
    case pointCloud

    var toggled: PrimaryContent {
        self == .video ? .pointCloud : .video
    }
}

@MainActor
@Observable
final class ViewportLayoutState {
    private static let primaryContentKey = "primaryViewportContent"
    private static let pipXKey = "pictureInPictureX"
    private static let pipYKey = "pictureInPictureY"

    private(set) var primary: PrimaryContent
    private(set) var pipPosition: CGPoint
    private(set) var isSwapping = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        primary = defaults.string(forKey: Self.primaryContentKey)
            .flatMap(PrimaryContent.init(rawValue:)) ?? .video
        pipPosition = CGPoint(
            x: Self.unit(defaults.object(forKey: Self.pipXKey) as? Double ?? 1),
            y: Self.unit(defaults.object(forKey: Self.pipYKey) as? Double ?? 1)
        )
    }

    func pipCenter(in container: CGSize, pipSize: CGSize, inset: CGFloat, drag: CGSize = .zero) -> CGPoint {
        let bounds = pipBounds(in: container, pipSize: pipSize, inset: inset)
        return CGPoint(
            x: min(max(bounds.minX + bounds.width * pipPosition.x + drag.width, bounds.minX), bounds.maxX),
            y: min(max(bounds.minY + bounds.height * pipPosition.y + drag.height, bounds.minY), bounds.maxY)
        )
    }

    func movePip(by drag: CGSize, in container: CGSize, pipSize: CGSize, inset: CGFloat) {
        let bounds = pipBounds(in: container, pipSize: pipSize, inset: inset)
        let center = pipCenter(in: container, pipSize: pipSize, inset: inset, drag: drag)
        pipPosition = CGPoint(
            x: bounds.width > 0 ? (center.x - bounds.minX) / bounds.width : 0.5,
            y: bounds.height > 0 ? (center.y - bounds.minY) / bounds.height : 0.5
        )
        defaults.set(Double(pipPosition.x), forKey: Self.pipXKey)
        defaults.set(Double(pipPosition.y), forKey: Self.pipYKey)
    }

    func swap() {
        guard !isSwapping else { return }
        isSwapping = true
        primary = primary.toggled
        defaults.set(primary.rawValue, forKey: Self.primaryContentKey)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.isSwapping = false
        }
    }

    private func pipBounds(in container: CGSize, pipSize: CGSize, inset: CGFloat) -> CGRect {
        let minX = pipSize.width / 2 + inset
        let minY = pipSize.height / 2 + inset
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, container.width - 2 * minX),
            height: max(0, container.height - 2 * minY)
        )
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }
}
