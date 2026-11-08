import AppKit

/// Black windows behind the game windows while a session runs, so the bars around windows kept at their
/// aspect ratio (Game.MinAspectRatio) are black instead of the desktop. They sit just above the desktop icons,
/// below every app's windows, and let clicks through.
final class Backdrop {
    private var windows: [NSWindow] = []

    func show(on frames: [CGRect]) {
        hide()
        windows = frames.map { frame in
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = .black
            w.isOpaque = true
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.hasShadow = false
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.setFrame(frame, display: false)
            w.orderFront(nil)
            return w
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}
