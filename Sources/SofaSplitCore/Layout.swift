import CoreGraphics
import Foundation

public enum LayoutKind: String, CaseIterable, Codable, Identifiable {
    case disabled, full, sideBySide, stacked, three, quad, six, eight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .disabled: return "Not used"
        case .full: return "1 — Full screen"
        case .sideBySide: return "2 — Side by side"
        case .stacked: return "2 — Top / bottom"
        case .three: return "3 — One top, two bottom"
        case .quad: return "4 — Grid"
        case .six: return "6 — 3×2 grid"
        case .eight: return "8 — 4×2 grid"
        }
    }

    public var slotCount: Int { rects(in: CGRect(x: 0, y: 0, width: 100, height: 100)).count }

    /// Slot rectangles in Cocoa coordinates (origin bottom-left), ordered top-left first, row by row.
    public func rects(in r: CGRect) -> [CGRect] {
        switch self {
        case .disabled: return []
        case .full: return [r]
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
