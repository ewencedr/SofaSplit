import AppKit
import Combine
import SofaSplitCore
import SwiftUI

struct ScreenInfo: Identifiable {
    let id: Int
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
}

struct SlotID: Hashable, Codable {
    let screen: Int
    let slot: Int
}

final class AppModel: ObservableObject {
    let library = GameLibrary()
    let controllers = ControllerMonitor()
    let session = GameSession()

    @Published var selectedGameID: GameEntry.ID?
    @Published var screens: [ScreenInfo] = []
    @Published var layouts: [Int: LayoutKind] = [0: .sideBySide]
    @Published var assignments: [SlotID: Assignment] = [:]
    @Published var joinWithButton = true
    @Published var coverMenuBar = false
    @Published var logLines: [String] = []
    @Published var handlerError: String?

    private var bag: Set<AnyCancellable> = []

    init() {
        Paths.bootstrap()
        log.sink = { [weak self] line in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 500 { self.logLines.removeFirst(self.logLines.count - 500) }
        }
        refreshScreens()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.refreshScreens() }
            .store(in: &bag)

        // Forward nested ObservableObjects so views refresh.
        for publisher in [library.objectWillChange.eraseToAnyPublisher(),
                          controllers.objectWillChange.eraseToAnyPublisher(),
                          session.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }

        controllers.$devices.receive(on: RunLoop.main).sink { [weak self] devices in
            self?.dropDisconnected(devices)
        }.store(in: &bag)

        controllers.onButtonPress = { [weak self] device in
            DispatchQueue.main.async { self?.join(device) }
        }
        selectedGameID = library.games.first?.id
        // Games added by older versions haven't been analyzed yet.
        for game in library.games where game.profile == nil { reanalyze(game) }
    }

    var selectedGame: GameEntry? { library.games.first { $0.id == selectedGameID } }

    func refreshScreens() {
        screens = NSScreen.screens.enumerated().map {
            ScreenInfo(id: $0.offset, name: $0.element.localizedName, frame: $0.element.frame,
                       visibleFrame: $0.element.visibleFrame, scale: $0.element.backingScaleFactor)
        }
        layouts = layouts.filter { $0.key < screens.count }
    }

    // MARK: Slots

    func layout(for screen: Int) -> LayoutKind { layouts[screen] ?? .disabled }

    func setLayout(_ kind: LayoutKind, for screen: Int) {
        layouts[screen] = kind
        assignments = assignments.filter { $0.key.screen != screen || $0.key.slot < kind.slotCount }
    }

    func slotRects(for screen: ScreenInfo) -> [CGRect] {
        layout(for: screen.id).rects(in: coverMenuBar ? screen.frame : screen.visibleFrame)
    }

    var allSlotIDs: [SlotID] {
        screens.flatMap { s in (0..<layout(for: s.id).slotCount).map { SlotID(screen: s.id, slot: $0) } }
    }

    func assignment(_ id: SlotID) -> Assignment { assignments[id] ?? .none }

    func assign(_ a: Assignment, to id: SlotID) {
        // A device belongs to one player at a time.
        if a != .none { assignments = assignments.filter { $0.value != a } }
        assignments[id] = a
    }

    func playerNumber(for id: SlotID) -> Int? {
        let assigned = allSlotIDs.filter { assignment($0) != .none }
        return assigned.firstIndex(of: id).map { $0 + 1 }
    }

    func slotHolding(_ a: Assignment) -> SlotID? { assignments.first { $0.value == a }?.key }

    private func join(_ device: InputDevice) {
        guard joinWithButton, !session.isRunning else { return }
        let a = Assignment.gamepad(device.id)
        guard slotHolding(a) == nil else { return }
        if let free = allSlotIDs.first(where: { assignment($0) == .none }) {
            assign(a, to: free)
            log("\(device.name) joined slot \(free.slot + 1) on screen \(free.screen + 1)")
        }
    }

    func autoAssign() {
        assignments = [:]
        var queue = controllers.devices.map { Assignment.gamepad($0.id) }
        if queue.isEmpty { queue = [.keyboardMouse] }
        for id in allSlotIDs where !queue.isEmpty { assignments[id] = queue.removeFirst() }
    }

    private func dropDisconnected(_ devices: [InputDevice]) {
        let keys = Set(devices.map(\.id))
        assignments = assignments.filter {
            if case .gamepad(let k) = $0.value { return keys.contains(k) }
            return true
        }
    }

    func deviceName(_ a: Assignment) -> String {
        switch a {
        case .none: return "Empty"
        case .keyboardMouse: return "Keyboard & Mouse"
        case .gamepad(let key): return controllers.devices.first { $0.id == key }?.name ?? "Gamepad"
        }
    }

    // MARK: Games

    @Published var isAddingGame = false
    @Published var showSteamLibrary = false

    func chooseGameFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a game"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application, .unixExecutable, .item]
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addGame(at: url)
    }

    /// Analyzing reads the game's files, so it runs in the background.
    func addGame(at app: URL, name: String? = nil) {
        if let existing = library.games.first(where: { $0.appPath == app.path }) {
            selectedGameID = existing.id
            return
        }
        isAddingGame = true
        DispatchQueue.global(qos: .userInitiated).async {
            let entry = GameLibrary.makeEntry(app: app, name: name)
            DispatchQueue.main.async {
                self.isAddingGame = false
                guard let entry else { return }
                self.library.games.append(entry)
                self.selectedGameID = entry.id
            }
        }
    }

    func reanalyze(_ game: GameEntry) {
        isAddingGame = true
        DispatchQueue.global(qos: .userInitiated).async {
            let profile = GameAnalyzer.analyze(game.appURL)
            DispatchQueue.main.async {
                self.isAddingGame = false
                guard let i = self.library.games.firstIndex(where: { $0.id == game.id }) else { return }
                self.library.games[i].profile = profile
            }
        }
    }

    @Published var steamGameList: [SteamLibrary.Game]?
    @Published var settingsExpanded = false

    func loadSteamGames() {
        DispatchQueue.global(qos: .userInitiated).async {
            let games = SteamLibrary.installedGames()
            DispatchQueue.main.async { self.steamGameList = games }
        }
    }

    func remove(_ game: GameEntry) {
        library.games.removeAll { $0.id == game.id }
        if selectedGameID == game.id { selectedGameID = library.games.first?.id }
    }

    func setHandler(_ file: String, for game: GameEntry) {
        guard let i = library.games.firstIndex(where: { $0.id == game.id }) else { return }
        library.games[i].handlerFile = file
    }

    // MARK: Settings

    func setOption(_ key: String, _ value: OptionValue?, for game: GameEntry) {
        guard let i = library.games.firstIndex(where: { $0.id == game.id }) else { return }
        var options = library.games[i].options ?? [:]
        options[key] = value
        library.games[i].options = options.isEmpty ? nil : options
    }

    func boolOption(_ key: String, default d: Bool, for game: GameEntry) -> Bool {
        if case .bool(let b)? = game.options?[key] { return b }
        return handler(for: game)?.bool(key, default: d) ?? d
    }

    func stringOption(_ key: String, for game: GameEntry) -> String {
        switch game.options?[key] {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        default: return handler(for: game)?.string(key) ?? ""
        }
    }

    /// Bundled handlers live inside the app; editing one makes a copy in the user's handlers folder,
    /// which then takes precedence.
    func editHandler(_ game: GameEntry) {
        let file = game.handlerFile
        let userCopy = Paths.handlers.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: userCopy.path) {
            try? FileManager.default.copyItem(at: game.handlerURL, to: userCopy)
            log("Copied \(file) to your handlers folder; your copy is used from now on.")
        }
        NSWorkspace.shared.open(userCopy)
    }

    /// Parsed handlers for display, reused until the file changes (views ask for it on every render).
    private var handlerCache: [URL: (modified: Date, handler: GameHandler)] = [:]

    func handler(for game: GameEntry) -> GameHandler? {
        let url = game.handlerURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let cached = handlerCache[url], cached.modified == modified {
            cached.handler.overrides = game.options ?? [:]
            return cached.handler
        }
        do {
            let h = try GameLibrary.handler(for: game)
            handlerCache[url] = (modified, h)
            if handlerError != nil { DispatchQueue.main.async { self.handlerError = nil } }
            return h
        } catch {
            let msg = error.localizedDescription
            if handlerError != msg { DispatchQueue.main.async { self.handlerError = msg } }
            return nil
        }
    }

    var handlerFiles: [String] { HandlerStore.files().keys.sorted() }

    // MARK: Play

    func play() {
        // A fresh handler: the session reads it on a background queue while the UI keeps using the cached one.
        guard let game = selectedGame, let handler = try? GameLibrary.handler(for: game) else { return }
        let slots: [PlayerSlot] = screens.flatMap { screen in
            slotRects(for: screen).enumerated().map { i, rect in
                PlayerSlot(screenIndex: screen.id, slotIndex: i, frame: rect, scale: screen.scale,
                           assignment: assignment(SlotID(screen: screen.id, slot: i)))
            }
        }
        session.start(handler: handler, app: game.appURL, slots: slots,
                      options: SessionOptions(gamepads: controllers.devices))
    }

    // MARK: Diagnostics

    /// Collects what's needed to debug a game into the clipboard, for bug reports.
    func copyDiagnostics() {
        func tail(_ url: URL, _ n: Int) -> String {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "(none)" }
            return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
        }
        func orNone(_ items: [String]) -> String { items.isEmpty ? "none" : items.joined(separator: ", ") }
        let info = Bundle.main.infoDictionary
        var out = ["SofaSplit \(info?["CFBundleShortVersionString"] as? String ?? "dev")",
                   "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                   "Gamepads: " + orNone(controllers.devices.map { "\($0.name) [\($0.id)]" })]
        if let game = selectedGame {
            out.append("Game: \(game.name) (\(game.appURL.lastPathComponent)), handler \(game.handlerFile)")
            if let p = game.profile {
                let a = p.assessment
                out.append("Analysis: \(a.verdict.rawValue); engine \(p.engine.rawValue) \(p.unityScripting ?? ""); steam app \(p.steamAppID ?? "-"); "
                           + "api=\(p.usesSteam) flat=\(p.steamViaFlatAPI) lobbies=\(p.steamLobbies) messages=\(p.steamMessages) "
                           + "sockets=\(p.steamSockets) legacyP2P=\(p.steamLegacyP2P) input=\(p.steamInput)")
            }
            out.append("Changed settings: " + orNone((game.options ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }))
            if let h = handler(for: game) {
                let dir = Paths.content.appendingPathComponent(h.guid)
                let instances = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("Instance") }.sorted { $0.path < $1.path }
                for inst in instances {
                    out.append("--- \(inst.lastPathComponent)/hook.log\n" + tail(inst.appendingPathComponent("hook.log"), 40))
                    out.append("--- \(inst.lastPathComponent)/output.log\n" + tail(inst.appendingPathComponent("output.log"), 40))
                }
            }
        }
        out.append("--- sofasplit.log\n" + tail(Paths.logFile, 80))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out.joined(separator: "\n"), forType: .string)
        log("Diagnostics copied to the clipboard — paste them into a GitHub issue.")
    }

    func stop() { session.stop() }
}
