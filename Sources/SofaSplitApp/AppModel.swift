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

    func addGame() {
        let panel = NSOpenPanel()
        panel.title = "Choose a game"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application, .unixExecutable, .item]
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let entry = library.add(app: url) { selectedGameID = entry.id }
    }

    func remove(_ game: GameEntry) {
        library.games.removeAll { $0.id == game.id }
        if selectedGameID == game.id { selectedGameID = library.games.first?.id }
    }

    func setHandler(_ file: String, for game: GameEntry) {
        guard let i = library.games.firstIndex(where: { $0.id == game.id }) else { return }
        library.games[i].handlerFile = file
    }

    /// Parsed handlers, reused until the file changes (views ask for it on every render).
    private var handlerCache: [URL: (modified: Date, handler: GameHandler)] = [:]

    func handler(for game: GameEntry) -> GameHandler? {
        let url = game.handlerURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let cached = handlerCache[url], cached.modified == modified { return cached.handler }
        do {
            let h = try GameHandler(url: url)
            handlerCache[url] = (modified, h)
            if handlerError != nil { DispatchQueue.main.async { self.handlerError = nil } }
            return h
        } catch {
            let msg = error.localizedDescription
            if handlerError != msg { DispatchQueue.main.async { self.handlerError = msg } }
            return nil
        }
    }

    var handlerFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Paths.handlers.path)) ?? [])
            .filter { $0.hasSuffix(".js") && !$0.hasPrefix("_") }.sorted()
    }

    // MARK: Play

    func play() {
        guard let game = selectedGame, let handler = handler(for: game) else { return }
        let slots: [PlayerSlot] = screens.flatMap { screen in
            slotRects(for: screen).enumerated().map { i, rect in
                PlayerSlot(screenIndex: screen.id, slotIndex: i, frame: rect, scale: screen.scale,
                           assignment: assignment(SlotID(screen: screen.id, slot: i)))
            }
        }
        session.start(handler: handler, app: game.appURL, slots: slots,
                      options: SessionOptions(gamepads: controllers.devices))
    }

    func stop() { session.stop() }
}
