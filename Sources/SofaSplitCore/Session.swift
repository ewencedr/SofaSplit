import AppKit
import Foundation

public struct SessionOptions {
    /// Connected gamepads in launcher order (tokens + GameController ordinal fallback).
    public var gamepads: [InputDevice]
    public init(gamepads: [InputDevice]) { self.gamepads = gamepads }
}

/// Launches and supervises every instance of one split-screen session.
public final class GameSession: ObservableObject {
    public struct Instance {
        public let player: Int
        public let process: Process
        public let frame: CGRect
        public let hooked: Bool
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var status = ""
    public private(set) var instances: [Instance] = []
    public var onAllExited: (() -> Void)?

    private var cancelled = false
    private var steamEmuDir: URL?
    private let queue = DispatchQueue(label: "sofasplit.session")

    public init() {}

    public func start(handler: GameHandler, app: URL, slots: [PlayerSlot], options: SessionOptions) {
        guard !isRunning else { return }
        let players = slots.filter { $0.assignment != .none }
        guard !players.isEmpty else { log("No players assigned — assign a gamepad or the keyboard to a slot first."); return }
        isRunning = true
        cancelled = false
        instances = []
        queue.async { self.launchAll(handler: handler, app: app, players: players, options: options) }
    }

    public func stop() {
        cancelled = true
        let procs = instances.map(\.process)
        queue.async {
            for p in procs where p.isRunning { p.terminate() }
            Thread.sleep(forTimeInterval: 2)
            for p in procs where p.isRunning { kill(p.processIdentifier, SIGKILL) }
            DispatchQueue.main.async { self.finish("Stopped") }
        }
    }

    private func setStatus(_ s: String) {
        log(s)
        DispatchQueue.main.async { self.status = s }
    }

    private func finish(_ s: String) {
        isRunning = false
        status = s
        if let dir = steamEmuDir {
            try? FileManager.default.removeItem(at: dir)
            steamEmuDir = nil
        }
        onAllExited?()
    }

    private func launchAll(handler: GameHandler, app: URL, players: [PlayerSlot], options: SessionOptions) {
        let inject = handler.bool("Hook.Inject", default: true)
        let hookPath = Paths.hookLibrary
        if inject && hookPath == nil { log("⚠️ libSofaSplitHook.dylib not found — gamepad routing and focus hooks are disabled.") }
        let hooked = inject && hookPath != nil
        if hooked && handler.bool("Hook.SteamMultiplayer", default: false) {
            // Fresh rendezvous folder for the instances' lobby/P2P sockets (short path: sun_path is 104 bytes).
            let dir = URL(fileURLWithPath: "/tmp/sofasplit-\(getuid())-\(handler.guid.prefix(24))")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            steamEmuDir = dir
        } else {
            steamEmuDir = nil
        }

        let positioning = handler.string("Hook.WindowPositioning") ?? "auto"   // auto | hook | accessibility | none
        let useHookFrame = hooked && (positioning == "auto" || positioning == "hook")
        let useAX = positioning == "accessibility" || (positioning == "auto" && !hooked)
        if useAX && !WindowPositioner.isTrusted {
            log("⚠️ Accessibility permission missing — windows can't be positioned. Grant it in System Settings › Privacy & Security › Accessibility.")
        }

        let pause = Double(handler.int("PauseBetweenStarts", default: 1500)) / 1000
        let maxPlayers = handler.maxPlayers
        if players.count > maxPlayers { log("⚠️ Handler says the game supports \(maxPlayers) players; launching \(players.count) anyway.") }

        for (i, slot) in players.enumerated() {
            if cancelled { return }
            setStatus("Preparing player \(i + 1) of \(players.count)…")
            do {
                let inst = try InstanceBuilder.prepare(handler: handler, source: app, index: i, inject: hooked)
                if let bid = inst.bundleIdentifier, inst.appURL != app {
                    // Only touch our clones' own preference domains: keep App Nap off for background instances.
                    CFPreferencesSetAppValue("NSAppSleepDisabled" as CFString, kCFBooleanTrue, bid as CFString)
                    CFPreferencesAppSynchronize(bid as CFString)
                }

                var env = handler.dictionary("Environment")
                var args = handler.string("StartArguments") ?? ""
                let ctx = PlayContext(playerIndex: i, playerCount: players.count, frame: slot.frame, scale: slot.scale,
                                      instanceRoot: inst.root, appURL: inst.appURL, homeURL: inst.homeURL,
                                      bundleIdentifier: inst.bundleIdentifier, startArguments: args,
                                      environment: env, assignment: slot.assignment)
                (args, env) = try handler.runPlay(ctx)

                let process = try launch(inst: inst, slot: slot, player: i, args: expand(args, slot: slot, player: i, inst: inst),
                                         extraEnv: env, hookPath: hooked ? hookPath : nil, handler: handler,
                                         useHookFrame: useHookFrame, options: options)
                let instance = Instance(player: i, process: process, frame: slot.frame, hooked: hooked)
                DispatchQueue.main.sync { self.instances.append(instance) }
                log("P\(i + 1): started pid \(process.processIdentifier) (\(describe(slot.assignment)))")
                if useAX {
                    let pid = process.processIdentifier
                    DispatchQueue.global().async { self.placeWithAccessibility(pid: pid, frame: slot.frame) }
                }
            } catch {
                setStatus("Player \(i + 1) failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.stop() }
                return
            }
            if i < players.count - 1 { Thread.sleep(forTimeInterval: pause) }
        }
        setStatus("Running \(players.count) instance\(players.count == 1 ? "" : "s")")
    }

    private func describe(_ a: Assignment) -> String {
        switch a {
        case .none: return "no input"
        case .keyboardMouse: return "keyboard & mouse"
        case .gamepad(let k): return "gamepad \(k)"
        }
    }

    private func expand(_ args: String, slot: PlayerSlot, player: Int, inst: PreparedInstance) -> [String] {
        let vars: [String: String] = [
            "%PLAYER%": "\(player + 1)", "%PLAYERID%": "\(player)",
            "%WIDTH%": "\(Int(slot.frame.width))", "%HEIGHT%": "\(Int(slot.frame.height))",
            "%PIXELWIDTH%": "\(Int(slot.frame.width * slot.scale))", "%PIXELHEIGHT%": "\(Int(slot.frame.height * slot.scale))",
            "%X%": "\(Int(slot.frame.minX))", "%Y%": "\(Int(slot.frame.minY))",
            "%INSTANCE%": inst.root.path,
        ]
        let expanded = vars.reduce(args) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        return Self.splitArguments(expanded)
    }

    /// Splits a command line on whitespace, honouring "double" and 'single' quotes.
    public static func splitArguments(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var hasToken = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; hasToken = true
            } else if ch.isWhitespace {
                if hasToken { out.append(cur); cur = ""; hasToken = false }
            } else {
                cur.append(ch); hasToken = true
            }
        }
        if hasToken { out.append(cur) }
        return out
    }

    private func launch(inst: PreparedInstance, slot: PlayerSlot, player: Int, args: [String], extraEnv: [String: String],
                        hookPath: URL?, handler: GameHandler, useHookFrame: Bool, options: SessionOptions) throws -> Process {
        var env = ProcessInfo.processInfo.environment
        env["SOFASPLIT_PLAYER"] = "\(player + 1)"
        env["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"

        if let steamID = handler.string("SteamID"), !steamID.isEmpty {
            // What the Steam client sets when it launches a game: stops RestartAppIfNecessary from
            // closing the clone and relaunching the original through Steam.
            env["SteamAppId"] = steamID
            env["SteamGameId"] = steamID
        }
        if let home = inst.homeURL {
            env["HOME"] = home.path
            env["CFFIXED_USER_HOME"] = home.path
        }

        if let hookPath {
            env["DYLD_INSERT_LIBRARIES"] = [hookPath.path, env["DYLD_INSERT_LIBRARIES"]].compactMap { $0 }.joined(separator: ":")
            env["SOFASPLIT_HOOK_LOG"] = inst.root.appendingPathComponent("hook.log").path
            if let steamEmuDir {
                // Per-player Steam identity, lobbies and P2P between instances (see Hook/SteamLobbyEmu.m).
                env["SOFASPLIT_STEAM_EMU"] = "1"
                env["SOFASPLIT_STEAM_EMU_DIR"] = steamEmuDir.path
            }
            if handler.bool("Hook.GamepadRouting", default: true) {
                switch slot.assignment {
                case .gamepad(let key):
                    env["SOFASPLIT_ALLOWED_DEVICES"] = key
                    if let ord = options.gamepads.firstIndex(where: { $0.id == key }) { env["SOFASPLIT_GAMEPAD_ORDINALS"] = "\(ord)" }
                case .keyboardMouse, .none:
                    env["SOFASPLIT_ALLOWED_DEVICES"] = "none"
                }
                if handler.bool("Hook.SteamInput", default: false) {
                    // Gamepads arrive through Steam Input (filtered by ordinal in the hook);
                    // hide raw HID/GameController pads so none reaches the game twice.
                    env["SOFASPLIT_ALLOWED_DEVICES"] = "none"
                }
                env["SOFASPLIT_DEVICE_TOKENS"] = options.gamepads
                    .map { "\($0.id)=\($0.tokens.joined(separator: ","))" }.joined(separator: ";")
            }
            if handler.bool("Hook.ForceFocus", default: true) { env["SOFASPLIT_FORCE_FOCUS"] = "1" }
            if handler.bool("Hook.LegacyControllerNames", default: false) { env["SOFASPLIT_LEGACY_PAD_NAMES"] = "1" }
            if handler.bool("Hook.PlayStationBluetooth", default: true) { env["SOFASPLIT_DS4_BLUETOOTH"] = "1" }
            if useHookFrame {
                let f = slot.frame
                env["SOFASPLIT_WINDOW_FRAME"] = "\(f.minX),\(f.minY),\(f.width),\(f.height)"
                if handler.bool("Hook.Borderless", default: true) { env["SOFASPLIT_BORDERLESS"] = "1" }
            }
        }
        for (k, v) in extraEnv { env[k] = v }

        let p = Process()
        p.executableURL = inst.executableURL
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = inst.workingDirectory
        let outURL = inst.root.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        if let out = try? FileHandle(forWritingTo: outURL) {
            p.standardOutput = out
            p.standardError = out
        }
        p.terminationHandler = { [weak self] proc in
            log("P\(player + 1): exited with status \(proc.terminationStatus)")
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                if self.instances.allSatisfy({ !$0.process.isRunning }) && !self.cancelled {
                    self.finish("All instances exited")
                }
            }
        }
        try p.run()
        return p
    }

    private func placeWithAccessibility(pid: pid_t, frame: CGRect) {
        // Wait for the window to show up, then keep nudging it for a few seconds while the game settles.
        let deadline = Date().addingTimeInterval(30)
        var placedAt: Date?
        while Date() < deadline && !cancelled {
            let ok = DispatchQueue.main.sync { WindowPositioner.place(pid: pid, frame: frame) }
            if ok && placedAt == nil { placedAt = Date() }
            if let t = placedAt, Date().timeIntervalSince(t) > 4 { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if placedAt == nil { log("No window found for pid \(pid) to position") }
    }
}
