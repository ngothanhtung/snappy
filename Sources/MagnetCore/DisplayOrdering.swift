import CoreGraphics

/// Chooses the next/previous screen relative to the current one, ordered
/// left-to-right then top-to-bottom, wrapping around. Pure.
public enum DisplayOrdering {
    public enum Direction: Sendable { case next, previous }

    public static func target(from current: CGRect, in screens: [CGRect],
                              direction: Direction) -> CGRect? {
        guard screens.count > 1 else { return nil }
        let ordered = screens.sorted {
            $0.minX != $1.minX ? $0.minX < $1.minX : $0.minY < $1.minY
        }
        guard let index = ordered.firstIndex(of: current) else { return nil }
        let step = direction == .next ? 1 : -1
        let wrapped = (index + step + ordered.count) % ordered.count
        return ordered[wrapped]
    }
}
