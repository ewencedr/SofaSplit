import AppKit
import SofaSplitCore
import SwiftUI

@main
struct SofaSplitMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SofaSplit") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add from Steam Library…") { model.showSteamLibrary = true }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Add Game…") { model.chooseGameFile() }.keyboardShortcut("o")
                Divider()
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Button("Open Handlers Folder") { NSWorkspace.shared.open(Paths.handlers) }
                Button("Open Instances Folder") { NSWorkspace.shared.open(Paths.content) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedGameID) {
                Section("Games") {
                    ForEach(model.library.games) { game in
                        GameRow(game: game).tag(game.id)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.appURL]) }
                                Button("Remove", role: .destructive) { model.remove(game) }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("From Steam Library…") { model.showSteamLibrary = true }
                        Button("Choose App…") { model.chooseGameFile() }
                    } label: { Label("Add Game", systemImage: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    if model.isAddingGame { ProgressView().controlSize(.small) }
                }
                .padding(10)
            }
        } detail: {
            if let game = model.selectedGame {
                GameDetailView(game: game)
            } else {
                ContentUnavailableView {
                    Label("No game selected", systemImage: "gamecontroller")
                } description: {
                    Text("Add a game to play it in split-screen, with one gamepad per player.")
                } actions: {
                    Button("Add from Steam Library…") { model.showSteamLibrary = true }.buttonStyle(.borderedProminent)
                    Button("Choose App…") { model.chooseGameFile() }
                }
            }
        }
        .sheet(isPresented: $model.showSteamLibrary) { SteamLibrarySheet() }
    }
}

struct GameRow: View {
    let game: GameEntry
    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: game.appPath)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading) {
                Text(game.name).lineLimit(1)
                if game.handlerFile != "Generic.js" {
                    Text("Supported").font(.caption).foregroundStyle(.green).lineLimit(1)
                } else if let verdict = game.profile?.assessment.verdict {
                    Text(verdict.label).font(.caption).foregroundStyle(verdict.color).lineLimit(1)
                }
            }
        }
    }
}

struct GameDetailView: View {
    @EnvironmentObject var model: AppModel
    let game: GameEntry

    var body: some View {
        let handler = model.handler(for: game)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(handler)
                    if let err = model.handlerError {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !FileManager.default.fileExists(atPath: game.appPath) {
                        Label("Game not found at \(game.appPath)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    CompatibilityBox(game: game)
                    HStack(alignment: .top, spacing: 18) {
                        DevicesPanel().frame(width: 250)
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.screens) { ScreenPanel(screen: $0) }
                        }
                    }
                    optionsRow(handler)
                    GameSettingsBox(game: game)
                }
                .padding(20)
            }
            Divider()
            playBar(handler)
            LogView().frame(height: 130)
        }
        .navigationTitle(game.name)
    }

    func header(_ handler: GameHandler?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: game.appPath)).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.title2.bold())
                Text(game.appPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let notes = handler?.notes { Text(notes).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            Picker("Handler", selection: Binding(get: { game.handlerFile }, set: { model.setHandler($0, for: game) })) {
                ForEach(model.handlerFiles, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 230)
            Button("Edit…") { model.editHandler(game) }
                .help("Opens the handler script. Built-in handlers are copied to your handlers folder first.")
        }
    }

    func optionsRow(_ handler: GameHandler?) -> some View {
        HStack(spacing: 20) {
            Toggle("Press a button on a gamepad to join", isOn: $model.joinWithButton)
            Toggle("Cover menu bar & Dock", isOn: $model.coverMenuBar)
            Spacer()
            Button("Auto-assign") { model.autoAssign() }
            Button("Clear") { model.assignments = [:] }
        }
        .toggleStyle(.checkbox)
    }

    func playBar(_ handler: GameHandler?) -> some View {
        let shared = model.sharedSlot != nil
        let players = shared ? max(1, model.controllers.devices.count)
                             : model.allSlotIDs.filter { model.assignment($0) != .none }.count
        let needsAX = handler.map { !$0.bool("Hook.Inject", default: true) || $0.string("Hook.WindowPositioning") == "accessibility" } ?? false
        return HStack {
            if needsAX && !WindowPositioner.isTrusted {
                Button { WindowPositioner.requestTrust() } label: {
                    Label("Grant Accessibility to position windows", systemImage: "lock.shield")
                }
            }
            Text(model.session.status.isEmpty
                 ? (shared ? "Shared screen · \(players) player\(players == 1 ? "" : "s")"
                           : "\(players) player\(players == 1 ? "" : "s") ready")
                 : model.session.status)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy Diagnostics") { model.copyDiagnostics() }
                .buttonStyle(.borderless)
                .help("Copies logs and settings for a bug report")
            if model.session.isRunning {
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(width: 90) }
                    .controlSize(.large)
            } else {
                Button { model.play() } label: { Label("Play", systemImage: "play.fill").frame(width: 90) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(players == 0 || handler == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }
}

struct DevicesPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("Input devices") {
            VStack(alignment: .leading, spacing: 8) {
                if model.controllers.devices.isEmpty {
                    Text("No gamepads detected. Connect controllers over USB or Bluetooth.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.controllers.devices) { d in
                    row(icon: "gamecontroller.fill", name: d.name, detail: d.id, monospaced: true, assignment: .gamepad(d.id))
                }
                row(icon: "keyboard", name: "Keyboard & Mouse", detail: "Goes to the focused window", monospaced: false, assignment: .keyboardMouse)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    func row(icon: String, name: String, detail: String, monospaced: Bool, assignment: Assignment) -> some View {
        let slot = model.slotHolding(assignment)
        return HStack {
            Image(systemName: icon).frame(width: 22)
            VStack(alignment: .leading) {
                Text(name).lineLimit(1)
                Text(detail).font(monospaced ? .caption2.monospaced() : .caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let slot, let p = model.playerNumber(for: slot) {
                Text("P\(p)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
            }
        }
    }
}

struct ScreenPanel: View {
    @EnvironmentObject var model: AppModel
    let screen: ScreenInfo

    var body: some View {
        GroupBox {
            VStack(alignment: .leading) {
                Picker("Layout", selection: Binding(get: { model.layout(for: screen.id) },
                                                    set: { model.setLayout($0, for: screen.id) })) {
                    ForEach(LayoutKind.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 320)
                if model.layout(for: screen.id) != .disabled { preview }
            }
            .padding(6)
        } label: {
            // String(...) so the size isn't formatted with a thousands separator ("1.728×1.117").
            Text("Screen \(screen.id + 1) — \(screen.name)  " + String(Int(screen.frame.width)) + "×" + String(Int(screen.frame.height)))
        }
    }

    var preview: some View {
        let full = screen.frame
        return GeometryReader { geo in
            let scale = geo.size.width / full.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75))
                ForEach(Array(model.slotRects(for: screen).enumerated()), id: \.offset) { i, rect in
                    SlotView(id: SlotID(screen: screen.id, slot: i))
                        .frame(width: rect.width * scale - 4, height: rect.height * scale - 4)
                        .offset(x: (rect.minX - full.minX) * scale + 2, y: (full.maxY - rect.maxY) * scale + 2)
                }
            }
        }
        .aspectRatio(full.width / full.height, contentMode: .fit)
        .frame(maxWidth: 400, maxHeight: 260)
    }
}

struct SlotView: View {
    @EnvironmentObject var model: AppModel
    let id: SlotID

    var body: some View {
        if model.layout(for: id.screen).isShared { shared } else { slot }
    }

    var shared: some View {
        let n = model.controllers.devices.count
        return ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.55))
            VStack(spacing: 4) {
                Image(systemName: "person.3.fill").font(.title2)
                Text("All controllers").font(.headline)
                Text(n == 0 ? "Connect controllers, or play with keyboard & mouse"
                            : "\(n) controller\(n == 1 ? "" : "s") in one window — for games with their own local co-op")
                    .font(.caption).lineLimit(3).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(6)
        }
    }

    var slot: some View {
        let a = model.assignment(id)
        return Menu {
            Button("Empty") { model.assign(.none, to: id) }
            Button("Keyboard & Mouse") { model.assign(.keyboardMouse, to: id) }
            if !model.controllers.devices.isEmpty { Divider() }
            ForEach(model.controllers.devices) { d in
                Button("\(d.name)  (\(d.id))") { model.assign(.gamepad(d.id), to: id) }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(a == .none ? Color.gray.opacity(0.25) : Color.accentColor.opacity(0.55))
                VStack(spacing: 4) {
                    Image(systemName: icon(a)).font(.title2)
                    if let p = model.playerNumber(for: id) { Text("Player \(p)").font(.headline) }
                    Text(a == .none ? (model.joinWithButton ? "Press a button to join" : "Click to assign") : model.deviceName(a))
                        .font(.caption).lineLimit(2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(4)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    func icon(_ a: Assignment) -> String {
        switch a {
        case .none: return "plus.circle"
        case .keyboardMouse: return "keyboard"
        case .gamepad: return "gamecontroller.fill"
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.logLines.isEmpty {
                        Text("Messages from SofaSplit and the games appear here.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.logLines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
    }
}

extension GameProfile.Verdict {
    var label: String {
        switch self {
        case .likely: return "Likely works"
        case .maybe: return "Might work"
        case .unlikely: return "Probably won't work"
        }
    }

    var icon: String {
        switch self {
        case .likely: return "checkmark.circle.fill"
        case .maybe: return "questionmark.circle.fill"
        case .unlikely: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .likely: return .green
        case .maybe: return .orange
        case .unlikely: return .red
        }
    }
}

/// What the analyzer found, in plain language.
struct CompatibilityBox: View {
    @EnvironmentObject var model: AppModel
    let game: GameEntry

    var body: some View {
        GroupBox {
            if game.handlerFile != "Generic.js" {
                // A handler made for this game beats the analyzer's guess.
                HStack {
                    Label("Supported", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                    Text("SofaSplit has settings made for this game.").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(4)
            } else if let profile = game.profile {
                let (verdict, reasons) = profile.assessment
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(verdict.label, systemImage: verdict.icon).font(.headline).foregroundStyle(verdict.color)
                        Spacer()
                        Text([profile.engine == .other ? nil : profile.engine.rawValue,
                              profile.steamAppID.map { "Steam \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Check Again") { model.reanalyze(game) }.controlSize(.small)
                    }
                    ForEach(reasons, id: \.self) { Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } else {
                HStack {
                    Text("This game hasn't been checked yet.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Compatibility") { model.reanalyze(game) }
                }
                .padding(4)
            }
        }
    }
}

/// The handler options most games need, as checkboxes. Values set here override the handler script.
struct GameSettingsBox: View {
    @EnvironmentObject var model: AppModel
    let game: GameEntry

    // No @State: SwiftUI's State macro needs a compiler plugin that the Command Line Tools don't always load.
    var body: some View {
        DisclosureGroup(isExpanded: $model.settingsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                toggle("Hook.GamepadRouting", true, "One gamepad per window",
                       "Each window only sees the controller assigned to its player.")
                toggle("Hook.SteamInput", false, "Route Steam Input controllers",
                       "For games that read controllers through Steam Input. Lights each pad in its player's colour.")
                toggle("Hook.SteamMultiplayer", false, "Steam multiplayer between windows",
                       "Gives every window its own Steam identity so they can join each other's Steam lobbies.")
                toggle("IsolateHome", false, "Separate saves for each player",
                       "Each player gets their own copy of the game's save and settings folder.")
                toggle("Hook.ForceFocus", true, "Keep every window running",
                       "Background windows keep playing and reading their controller.")
                toggle("Hook.Borderless", true, "Borderless windows", "Removes the title bar from each game window.")
                aspectPicker
                field("SteamID", "Steam App ID", "Needed for Steam games started outside Steam, e.g. 2879840")
                field("StartArguments", "Extra launch arguments", "Passed to every copy of the game")
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Game settings").font(.headline)
                Text("Set automatically when the game was added. Change them if the game misbehaves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func toggle(_ key: String, _ defaultValue: Bool, _ title: String, _ help: String) -> some View {
        Toggle(isOn: Binding(get: { model.boolOption(key, default: defaultValue, for: game) },
                             set: { model.setOption(key, .bool($0), for: game) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    /// Game.MinAspectRatio: how narrow a window the game gets in a side-by-side slot.
    var aspectPicker: some View {
        let choices: [(value: String, title: String)] = [("", "Fill the slot"), ("4:3", "At least 4:3"),
                                                         ("16:10", "At least 16:10"), ("16:9", "At least 16:9")]
        let current = model.stringOption("MinAspectRatio", for: game)
        return HStack(alignment: .firstTextBaseline) {
            Text("Window shape").frame(width: 160, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Picker("", selection: Binding(get: { current },
                                              set: { model.setOption("MinAspectRatio", .string($0), for: game) })) {
                    ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
                    if !choices.contains(where: { $0.value == current }) { Text(current).tag(current) }
                }
                .labelsHidden()
                .fixedSize()
                Text("For games that look squashed or cropped side by side: their window gets shorter (black bars "
                     + "above and below) instead of almost square.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func field(_ key: String, _ title: String, _ prompt: String) -> some View {
        HStack {
            Text(title).frame(width: 160, alignment: .leading)
            TextField(prompt, text: Binding(get: { model.stringOption(key, for: game) },
                                            set: { model.setOption(key, $0.isEmpty ? nil : .string($0), for: game) }))
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// Installed Steam games with a Mac version, to add with one click.
struct SteamLibrarySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let games = model.steamGameList
        VStack(alignment: .leading, spacing: 0) {
            Text("Add from Steam Library").font(.title2.bold()).padding()
            Divider()
            Group {
                if let games, games.isEmpty {
                    ContentUnavailableView("No Mac Steam games found", systemImage: "gamecontroller",
                                           description: Text("Install a game in Steam, or use Choose App… to pick one yourself."))
                } else if let games {
                    List(games) { g in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: g.app.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading) {
                                Text(g.name)
                                Text(g.app.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.library.games.contains(where: { $0.appPath == g.app.path }) {
                                Text("Added").foregroundStyle(.secondary)
                            } else {
                                Button("Add") {
                                    model.addGame(at: g.app, name: g.name)
                                    dismiss()
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 300)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
        .onAppear { model.loadSteamGames() }
    }
}
