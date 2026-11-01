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
                Button("Add Game…") { model.addGame() }.keyboardShortcut("o")
                Divider()
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
                Button { model.addGame() } label: { Label("Add Game…", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let game = model.selectedGame {
                GameDetailView(game: game)
            } else {
                ContentUnavailableView {
                    Label("No game selected", systemImage: "gamecontroller")
                } description: {
                    Text("Add a game (.app) to play it in split-screen with one gamepad per player.")
                } actions: {
                    Button("Add Game…") { model.addGame() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct GameRow: View {
    let game: GameEntry
    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: game.appPath)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading) {
                Text(game.name).lineLimit(1)
                Text(game.handlerFile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    HStack(alignment: .top, spacing: 18) {
                        DevicesPanel().frame(width: 250)
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.screens) { ScreenPanel(screen: $0) }
                        }
                    }
                    optionsRow(handler)
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
            Button("Edit") { NSWorkspace.shared.open(game.handlerURL) }
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
        let players = model.allSlotIDs.filter { model.assignment($0) != .none }.count
        let needsAX = handler.map { !$0.bool("Hook.Inject", default: true) || $0.string("Hook.WindowPositioning") == "accessibility" } ?? false
        return HStack {
            if needsAX && !WindowPositioner.isTrusted {
                Button { WindowPositioner.requestTrust() } label: {
                    Label("Grant Accessibility to position windows", systemImage: "lock.shield")
                }
            }
            Text(model.session.status.isEmpty ? "\(players) player\(players == 1 ? "" : "s") ready" : model.session.status)
                .foregroundStyle(.secondary)
            Spacer()
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
                    row(icon: "gamecontroller.fill", name: d.name, detail: d.id, assignment: .gamepad(d.id))
                }
                row(icon: "keyboard", name: "Keyboard & Mouse", detail: "Goes to the focused window", assignment: .keyboardMouse)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    func row(icon: String, name: String, detail: String, assignment: Assignment) -> some View {
        let slot = model.slotHolding(assignment)
        return HStack {
            Image(systemName: icon).frame(width: 22)
            VStack(alignment: .leading) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
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
                preview
            }
            .padding(6)
        } label: {
            Text("Screen \(screen.id + 1) — \(screen.name)  \(Int(screen.frame.width))×\(Int(screen.frame.height))")
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
        .frame(maxWidth: 560)
    }
}

struct SlotView: View {
    @EnvironmentObject var model: AppModel
    let id: SlotID

    var body: some View {
        let a = model.assignment(id)
        Menu {
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
