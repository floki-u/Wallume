import AppKit
import CoreGraphics
import Foundation

public struct WindowSnapshot: Equatable, Sendable {
    public let ownerPID: pid_t
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect
    public let isOnscreen: Bool

    public init(ownerPID: pid_t, layer: Int, alpha: Double, bounds: CGRect, isOnscreen: Bool) {
        self.ownerPID = ownerPID; self.layer = layer; self.alpha = alpha
        self.bounds = bounds; self.isOnscreen = isOnscreen
    }
}

public protocol WindowSnapshotProviding: Sendable {
    func snapshots() -> [WindowSnapshot]?
}

public struct WindowOcclusionEvaluator: Sendable {
    public init() {}

    public func allDisplaysObscured(displays: [DesktopScreen], windows: [WindowSnapshot], ownPID: pid_t) -> Bool {
        guard !displays.isEmpty else { return false }
        let eligible = windows.filter {
            $0.ownerPID != ownPID && $0.layer == 0 && $0.alpha > 0 && $0.isOnscreen && !$0.bounds.isEmpty
        }
        return displays.allSatisfy { display in
            covers(display.frame, rectangles: eligible.map(\.bounds))
        }
    }

    private func covers(_ target: CGRect, rectangles: [CGRect]) -> Bool {
        let clipped = rectangles.map { $0.intersection(target) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Set(([target.minX, target.maxX] + clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xs.count >= 2 else { return false }
        for index in 0..<(xs.count - 1) where xs[index] < xs[index + 1] {
            let midpoint = (xs[index] + xs[index + 1]) / 2
            let intervals = clipped.filter { $0.minX <= midpoint && $0.maxX >= midpoint }
                .map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var covered = target.minY
            for interval in intervals where interval.1 > covered {
                guard interval.0 <= covered else { break }
                covered = max(covered, interval.1)
                if covered >= target.maxY { break }
            }
            if covered < target.maxY { return false }
        }
        return true
    }
}

public struct CGWindowSnapshotProvider: WindowSnapshotProviding {
    public init() {}

    public func snapshots() -> [WindowSnapshot]? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        var result = [WindowSnapshot]()
        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  let alpha = entry[kCGWindowAlpha as String] as? NSNumber,
                  let onscreen = entry[kCGWindowIsOnscreen as String] as? NSNumber,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { continue }
            let bounds = CGRect(x: cgBounds.minX, y: top - cgBounds.maxY, width: cgBounds.width, height: cgBounds.height)
            result.append(WindowSnapshot(ownerPID: pid.int32Value, layer: layer.intValue, alpha: alpha.doubleValue, bounds: bounds, isOnscreen: onscreen.boolValue))
        }
        return result
    }
}
