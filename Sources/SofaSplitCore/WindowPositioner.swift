import AppKit
import ApplicationServices

/// Places windows of other processes through the Accessibility API.
/// Used when the hook isn't injected (or as requested by the handler).
public enum WindowPositioner {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Converts a Cocoa global rect (bottom-left origin) to AX/CoreGraphics coordinates (top-left origin).
    static func axRect(_ r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Moves the largest window of `pid` into `frame`. Returns false if no window exists yet.
    @discardableResult
    public static func place(pid: pid_t, frame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return false }

        func size(of w: AXUIElement) -> CGSize {
            var v: CFTypeRef?
            var s = CGSize.zero
            if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &v) == .success, let v {
                AXValueGetValue(v as! AXValue, .cgSize, &s)
            }
            return s
        }
        guard let window = windows.max(by: { size(of: $0).width * size(of: $0).height < size(of: $1).width * size(of: $1).height })
        else { return false }

        let target = axRect(frame)
        var origin = target.origin
        var sz = target.size
        if let pos = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
        if let s = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        }
        // Set the position again: some windows are clamped while still at their old size.
        if let pos = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
        return true
    }
}
