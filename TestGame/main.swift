// Diagnostic "game": a window that reports what this instance can see.
import AppKit
import GameController
import IOKit.hid

final class Status: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let label = NSTextField(labelWithString: "")
    let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var resignCount = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 400),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let player = CommandLine.arguments.firstIndex(of: "--player").map { CommandLine.arguments[$0 + 1] } ?? "?"
        window.title = "Test Game — Player \(player)"
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.frame = window.contentView!.bounds.insetBy(dx: 16, dy: 16)
        label.autoresizingMask = [.width, .height]
        label.maximumNumberOfLines = 0
        window.contentView!.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let matching = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(hid, matching as CFArray)
        IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            self.resignCount += 1
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in self.update() }.fire()
    }

    func update() {
        let hidPads = (IOHIDManagerCopyDevices(hid) as? Set<IOHIDDevice>)?.compactMap {
            IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String
        } ?? []
        let gc = GCController.controllers().map { $0.vendorName ?? "?" }
        let f = window.frame
        let info: [String: Any] = [
            "pid": getpid(),
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "home": NSHomeDirectory(),
            "prefPlayerName": UserDefaults.standard.string(forKey: "PlayerName") ?? "",
            "appIsActive": NSApp.isActive,
            "windowIsKey": window.isKeyWindow,
            "resignActiveSeen": resignCount,
            "frame": [f.minX, f.minY, f.width, f.height],
            "borderless": window.styleMask == .borderless,
            "hidGamepads": hidPads,
            "gcControllers": gc,
            "hooked": ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil,
        ]
        label.stringValue = info.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        if let path = ProcessInfo.processInfo.environment["TESTGAME_STATUS"],
           let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

let app = NSApplication.shared
let delegate = Status()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
