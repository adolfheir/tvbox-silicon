import Foundation

/// A horizontal screen drag moves at a consistent scale on phones and tablets.
/// Freeze the origin and duration for the gesture; playback may keep advancing.
public struct PlaybackScrub: Sendable {
    public let origin: Double
    public let duration: Double
    private let width: Double

    public init?(position: Double, duration: Double, width: Double) {
        guard position.isFinite, duration.isFinite, duration > 0, width.isFinite, width > 0 else { return nil }
        origin = min(max(0, position), duration)
        self.duration = duration
        self.width = width
    }

    public static func isHorizontal(x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite && abs(x) >= 12 && abs(x) > abs(y) * 1.3
    }

    public func target(translation: Double) -> Double {
        guard translation.isFinite else { return origin }
        // One screen width is two minutes; ignore predicted velocity so lifting
        // the finger always seeks to the time actually shown in the preview.
        let delta = min(max(translation / width, -1), 1) * 120
        return min(max(0, origin + delta), duration)
    }
}
