import AppKit
import SofaSplitCore

let usage = """
usage: sofasplit <command>

  controllers                      List connected gamepads and their routing keys
  steam-games                      List installed Steam games that have a Mac version
  analyze <Game.app>               Check whether a game is likely to work and which settings it needs
  handlers                         List installed handlers
  play <Game.app|binary> [options] Launch a split-screen session
      --handler <file.js>          Handler to use (default: best match, else Generic.js)
      --layout <kind>              full | sideBySide | stacked | three | quad | six | eight (default: by player count)
      --players <n>                Number of instances (default: number of gamepads, at least 1)
      --screen <index>             Screen to use (default 0)
      --keyboard                   Give player 1 the keyboard & mouse instead of a gamepad
      --full-frame                 Cover the menu bar and Dock area too
      --set <Key>=<value>          Override a handler setting, e.g. --set Hook.SteamMultiplayer=true (repeatable)
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

Paths.bootstrap()
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch command {
case "controllers":
    let monitor = ControllerMonitor(scheduleOnMainRunLoop: false)
    if monitor.devices.isEmpty { print("No gamepads detected.") }
    for (i, d) in monitor.devices.enumerated() { print("\(i)  \(d.id)  \(d.name)") }

case "analyze":
    guard let target = args.first else { fail("usage: sofasplit analyze <Game.app>") }
    let app = URL(fileURLWithPath: (target as NSString).expandingTildeInPath).standardizedFileURL
    let p = GameAnalyzer.analyze(app)
    let (verdict, reasons) = p.assessment
    print("\(app.lastPathComponent): \(verdict.rawValue)")
    for r in reasons { print("  - \(r)") }
    print("  engine: \(p.engine.rawValue)\(p.unityScripting.map { " (\($0))" } ?? ""), steam app id: \(p.steamAppID ?? "-")")
    print("  steam: api=\(p.usesSteam) flat=\(p.steamViaFlatAPI) lobbies=\(p.steamLobbies) messages=\(p.steamMessages) sockets=\(p.steamSockets) legacyP2P=\(p.steamLegacyP2P) input=\(p.steamInput)")
    print("  suggested settings: \(p.suggestedOptions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")

case "steam-games":
    for g in SteamLibrary.installedGames() { print("\(g.id.padding(toLength: 9, withPad: " ", startingAt: 0)) \(g.name)  \(g.app.path)") }

case "handlers":
    print("Handlers in \(Paths.handlers.path):")
    for h in HandlerStore.all() {
        print("  \(h.url.lastPathComponent.padding(toLength: 24, withPad: " ", startingAt: 0)) \(h.gameName)  (max \(h.maxPlayers))")
    }

case "play":
    guard let target = args.first, !target.hasPrefix("--") else { fail(usage) }
    let app = URL(fileURLWithPath: (target as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: app.path) else { fail("Not found: \(app.path)") }

    let handler: GameHandler
    do {
        if let h = option("--handler") {
            let url = h.contains("/") ? URL(fileURLWithPath: h) : Paths.handlers.appendingPathComponent(h)
            handler = try GameHandler(url: url)
        } else if let h = HandlerStore.bestMatch(for: app) {
            handler = h
        } else { fail("No handler found") }
    } catch { fail(error.localizedDescription) }

    if handler.isGeneric {
        handler.overrides = GameAnalyzer.analyze(app).suggestedOptions
        handler.overrides["GUID"] = .string(app.deletingPathExtension().lastPathComponent)
    }
    for (i, arg) in args.enumerated() where arg == "--set" && i + 1 < args.count {
        let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("--set expects Key=value") }
        let value: OptionValue
        switch parts[1].lowercased() {
        case "true", "yes", "on": value = .bool(true)
        case "false", "no", "off": value = .bool(false)
        default: value = Int(parts[1]).map(OptionValue.int) ?? .string(parts[1])
        }
        handler.overrides[parts[0]] = value
    }

    _ = NSApplication.shared  // needed for NSScreen
    let monitor = ControllerMonitor(scheduleOnMainRunLoop: false)
    let pads = monitor.devices
    let keyboard = args.contains("--keyboard")
    let count = Int(option("--players") ?? "") ?? max(1, pads.count + (keyboard ? 1 : 0))
    let layout = option("--layout").flatMap(LayoutKind.init(rawValue:)) ?? {
        switch count {
        case 1: return .full
        case 2: return .sideBySide
        case 3: return .three
        case 4: return .quad
        case 5, 6: return .six
        default: return .eight
        }
    }()
    let screens = NSScreen.screens
    let screenIndex = Int(option("--screen") ?? "0") ?? 0
    guard screenIndex < screens.count else { fail("No screen \(screenIndex)") }
    let screen = screens[screenIndex]
    let area = args.contains("--full-frame") ? screen.frame : screen.visibleFrame
    let rects = layout.rects(in: area)
    guard count <= rects.count else { fail("Layout \(layout.rawValue) only has \(rects.count) slots") }

    var padQueue = pads.map { Assignment.gamepad($0.id) }
    var slots: [PlayerSlot] = []
    for i in 0..<count {
        // Players without a gamepad see no pads at all; keyboard & mouse reach whichever window has focus.
        let assignment: Assignment = (keyboard && i == 0) || padQueue.isEmpty ? .keyboardMouse : padQueue.removeFirst()
        slots.append(PlayerSlot(screenIndex: screenIndex, slotIndex: i, frame: rects[i],
                                scale: screen.backingScaleFactor, assignment: assignment))
    }

    print("Launching \(count) × \(handler.gameName) with \(handler.url.lastPathComponent), layout \(layout.rawValue). Ctrl-C stops all instances.")
    let session = GameSession()
    session.onAllExited = { exit(0) }
    // Ctrl-C or `kill` stops every instance before exiting.
    let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            print("\nStopping…")
            session.onAllExited = { exit(0) }
            session.stop()
        }
        source.resume()
        return source
    }
    session.start(handler: handler, app: app, slots: slots, options: SessionOptions(gamepads: pads))
    withExtendedLifetime(signalSources) { RunLoop.main.run() }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
