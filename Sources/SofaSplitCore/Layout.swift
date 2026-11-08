import CoreGraphics
import Foundation

public enum LayoutKind: String, CaseIterable, Codable, Identifiable {
    case disabled, full, shared, sideBySide, stacked, three, quad, six, eight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled: return "Not used"
        case .full: return "1 — Full screen"
        case .shared: return "Shared screen — all controllers in one window"
        case .sideBySide: return "2 — Side by side"
        case .stacked: return "2 — Top / bottom"
        case .three: return "3 — One top, two bottom"
        case .quad: return "4 — Grid"
        case .six: return "6 — 3×2 grid"
        case .eight: return "8 — 4×2 grid"
        }
    }

    /// One copy of the game that sees every controller: for games with their own local multiplayer, which then
    /// still get SofaSplit's controller fixes (PS4 pads on Bluetooth) and window placement.
    public var isShared: Bool { self == .shared }

    public var slotCount: Int { rects(in: CGRect(x: 0, y: 0, width: 100, height: 100)).count }

    /// Slot rectangles in Cocoa coordinates (origin bottom-left), ordered top-left first, row by row.
    public func rects(in r: CGRect) -> [CGRect] {
        switch self {
        case .disabled: return []
        case .full, .shared: return [r]
        case .sideBySide: return Self.grid(cols: 2, rows: 1, in: r)
        case .stacked: return Self.grid(cols: 1, rows: 2, in: r)
        case .three:
            let h = (r.height / 2).rounded(.down)
            let top = CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
            let bottom = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - h)
            return [top] + Self.grid(cols: 2, rows: 1, in: bottom)
        case .quad: return Self.grid(cols: 2, rows: 2, in: r)
        case .six: return Self.grid(cols: 3, rows: 2, in: r)
        case .eight: return Self.grid(cols: 4, rows: 2, in: r)
        }
    }

    static func grid(cols: Int, rows: Int, in r: CGRect) -> [CGRect] {
        let w = (r.width / CGFloat(cols)).rounded(.down)
        let h = (r.height / CGFloat(rows)).rounded(.down)
        var out: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<cols {
                // Last column/row absorbs the rounding remainder.
                let width = col == cols - 1 ? r.width - w * CGFloat(cols - 1) : w
                let height = row == rows - 1 ? r.height - h * CGFloat(rows - 1) : h
                out.append(CGRect(x: r.minX + w * CGFloat(col), y: r.maxY - h * CGFloat(row) - height,
                                  width: width, height: height))
            }
        }
        return out
    }
}

/// Window shapes a game copes with. Half of a 16:9 screen side by side is almost square, which many games
/// don't handle: menus that refuse anything narrower than 4:3, or a fixed vertical field of view that crops the
/// sides. With a minimum ratio, a slot narrower than it gets a shorter window, centred in the slot.
public enum AspectRatio {
    /// Parses "4:3", "16/9" or "1.333"; nil for "" or anything unreadable (= fill the slot).
    public static func parse(_ s: String?) -> CGFloat? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "/" })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let ratio: Double
        switch parts.count {
        case 1: ratio = parts[0]
        case 2 where parts[1] > 0: ratio = parts[0] / parts[1]
        default: ratio = 0
        }
        return ratio > 0 ? CGFloat(ratio) : nil
    }

    /// The largest rect of at least `minRatio` (width / height) inside `slot`, centred vertically; `slot` itself
    /// when it's already wide enough. Whole points, so the game gets an integral window size.
    public static func fit(_ slot: CGRect, minRatio: CGFloat?) -> CGRect {
        guard let minRatio, minRatio > 0, slot.height > 0, slot.width / slot.height < minRatio - 0.001 else { return slot }
        let height = (slot.width / minRatio).rounded(.down)
        return CGRect(x: slot.minX, y: (slot.midY - height / 2).rounded(.down), width: slot.width, height: height)
    }
}

public enum Assignment: Hashable, Codable {
    case none
    case keyboardMouse
    case gamepad(String)
}

public struct PlayerSlot: Hashable {
    public var screenIndex: Int
    public var slotIndex: Int
    /// Cocoa global coordinates (points).
    public var frame: CGRect
    public var scale: CGFloat
    public var assignment: Assignment

    public init(screenIndex: Int, slotIndex: Int, frame: CGRect, scale: CGFloat, assignment: Assignment) {
        self.screenIndex = screenIndex
        self.slotIndex = slotIndex
        self.frame = frame
        self.scale = scale
        self.assignment = assignment
    }
}
