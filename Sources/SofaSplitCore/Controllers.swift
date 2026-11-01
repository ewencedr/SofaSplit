import Foundation
import IOKit
import IOKit.hid

public struct InputDevice: Identifiable, Hashable, Codable {
    /// Stable "vid:pid:location" key — the same string SofaSplitHook computes inside the game.
    public let id: String
    public let name: String
    public let registryID: UInt64
    /// Identifiers GameController may expose for this pad (serial / Bluetooth address, location, registry id),
    /// normalized to lowercase hex without separators. Lets the hook map GCController objects to HID devices.
    public var tokens: [String] = []

    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { $0.isHexDigit })
    }

    /// The controller's Bluetooth address (12 hex digits) when known: the same physical pad over USB and over
    /// Bluetooth shares it, while its key changes with the connection.
    public var hardwareAddress: String? { tokens.first { $0.count == 12 } }
}

public enum ControllerIdentity {
    /// The Bluetooth address of a controller, over either connection. Over Bluetooth it is the serial number;
    /// PlayStation pads on USB report it in a feature report (DUALSHOCK 4: 0x12, DualSense: 0x09, bytes 1-6
    /// in reverse order). Must stay in sync with HardwareAddress() in Hook/SofaSplitHook.m.
    public static func hardwareAddress(of device: IOHIDDevice) -> String? {
        if let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String {
            let hex = InputDevice.normalize(serial)
            if hex.count == 12 { return hex }
        }
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard vid == 0x054c else { return nil }
        let report: (id: UInt8, length: Int)
        switch pid {
        case 0x05c4, 0x09cc: report = (0x12, 16)
        case 0x0ce6, 0x0df2: report = (0x09, 20)
        default: return nil
        }
        var buffer = [UInt8](repeating: 0, count: report.length)
        buffer[0] = report.id
        var length = CFIndex(report.length)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(report.id), &buffer, &length) == kIOReturnSuccess,
              length >= 7 else { return nil }
        let address = buffer[1...6].reversed().map { String(format: "%02x", $0) }.joined()
        return address == "000000000000" ? nil : address
    }
}

public enum DeviceKey {
    /// Walks up from any HID service to its IOHIDDevice and builds "vid:pid:location".
    /// Must stay in sync with KeyForService() in Hook/SofaSplitHook.m.
    public static func key(forService service: io_service_t) -> (key: String, registryID: UInt64)? {
        guard service != 0 else { return nil }
        var entry = service
        IOObjectRetain(entry)
        for _ in 0..<10 {
            if IOObjectConformsTo(entry, "IOHIDDevice") != 0 {
                defer { IOObjectRelease(entry) }
                var rid: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &rid)
                let vid = intProperty(entry, kIOHIDVendorIDKey) ?? 0
                let pid = intProperty(entry, kIOHIDProductIDKey) ?? 0
                let loc = intProperty(entry, kIOHIDLocationIDKey).map {
                    String(format: "%08x", UInt32(truncatingIfNeeded: $0))
                } ?? String(format: "r%llx", rid)
                let key = String(format: "%04x:%04x:", UInt32(truncatingIfNeeded: vid), UInt32(truncatingIfNeeded: pid)) + loc
                return (key, rid)
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            if kr != KERN_SUCCESS { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int64? {
        guard let v = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (v as? NSNumber)?.int64Value
    }
}

/// Watches connected gamepads/joysticks through IOKit HID and reports button presses
/// (used for "press a button to join").
public final class ControllerMonitor: ObservableObject {
    @Published public private(set) var devices: [InputDevice] = []
    public var onButtonPress: ((InputDevice) -> Void)?

    private let manager: IOHIDManager
    private var known: [UnsafeMutableRawPointer: InputDevice] = [:]

    public init(scheduleOnMainRunLoop: Bool = true) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let usages = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController]
        let matching = usages.map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<ControllerMonitor>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<ControllerMonitor>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            Unmanaged<ControllerMonitor>.fromOpaque(ctx!).takeUnretainedValue().input(value)
        }, ctx)
        // A DUALSHOCK 4 on Bluetooth sends only its extended report (0x11), never button values.
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, sender, _, reportID, report, length in
            guard reportID == 0x11, length >= 10, let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<ControllerMonitor>.fromOpaque(ctx!).takeUnretainedValue()
                .bluetoothReport(device, buttons: [report[7] & 0xF0, report[8], report[9] & 0x03])
        }, ctx)
        if scheduleOnMainRunLoop {
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        refreshFromManager()
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Synchronous enumeration (no run loop needed) — used by the CLI.
    public func refreshFromManager() {
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for d in set { added(d) }
    }

    private func describe(_ device: IOHIDDevice) -> InputDevice? {
        guard let (key, rid) = DeviceKey.key(forService: IOHIDDeviceGetService(device)) else { return nil }
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let maker = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
        var tokens: [String] = []
        if let address = ControllerIdentity.hardwareAddress(of: device) { tokens.append(address) }
        if let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String {
            let t = InputDevice.normalize(serial)
            if t.count >= 6 && !tokens.contains(t) { tokens.append(t) }
        }
        if let loc = key.split(separator: ":").last, !loc.hasPrefix("r") { tokens.append(String(loc)) }
        tokens.append(String(format: "%llx", rid))
        return InputDevice(id: key, name: product ?? maker ?? "Gamepad", registryID: rid, tokens: tokens)
    }

    private func added(_ device: IOHIDDevice) {
        let ptr = Unmanaged.passUnretained(device).toOpaque()
        guard known[ptr] == nil, let info = describe(device) else { return }
        known[ptr] = info
        publish()
    }

    private func removed(_ device: IOHIDDevice) {
        known.removeValue(forKey: Unmanaged.passUnretained(device).toOpaque())
        lastButtons.removeValue(forKey: Unmanaged.passUnretained(device).toOpaque())
        publish()
    }

    private func input(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetType(element) == kIOHIDElementTypeInput_Button,
              IOHIDValueGetIntegerValue(value) == 1 else { return }
        let device = IOHIDElementGetDevice(element)
        if let info = known[Unmanaged.passUnretained(device).toOpaque()] { onButtonPress?(info) }
    }

    private var lastButtons: [UnsafeMutableRawPointer: [UInt8]] = [:]

    private func bluetoothReport(_ device: IOHIDDevice, buttons: [UInt8]) {
        let ptr = Unmanaged.passUnretained(device).toOpaque()
        let before = lastButtons[ptr] ?? [0, 0, 0]
        lastButtons[ptr] = buttons
        let newlyPressed = zip(buttons, before).contains { now, was in now & ~was != 0 }
        if newlyPressed, let info = known[ptr] { onButtonPress?(info) }
    }

    private func publish() {
        // Registry IDs grow with connection order, which is also GameController's order.
        let sorted = known.values.sorted { $0.registryID < $1.registryID }
        // Dedupe: one physical pad can expose several matching interfaces.
        var seen = Set<String>()
        devices = sorted.filter { seen.insert($0.id).inserted }
    }
}
