# SofaSplit

Split-screen co-op on one Mac for games that only have online or LAN multiplayer.

SofaSplit launches one copy of a game per player, gives each copy its own gamepad, keeps every copy
running while another one has focus, and tiles the windows across your screen(s). For Steam games that
use lobbies, each copy also gets its own Steam identity, so the copies can join each other.

It is a native macOS project inspired by [Nucleus Co-op](https://github.com/SplitScreen-Me/splitscreenme-nucleus)
for Windows. It shares no code with it and is not affiliated with it.

## How it works

| Problem | What SofaSplit does |
|---|---|
| A game can only run once | Each player gets an APFS clone of the `.app` (no extra disk space) with its own bundle ID (`<id>.sofasplit<N>`), launched directly |
| Every window reacts to every controller | `libSofaSplitHook.dylib`, injected with `DYLD_INSERT_LIBRARIES`, hides all but the assigned pad from IOKit HID, GameController and Steam Input |
| Background windows pause or stop reading input | The hook keeps `NSApp.isActive` true, drops resign-active notifications, enables background controller events and disables App Nap |
| Windows need to be tiled | The hook places each window in its slot (optionally borderless) and blocks native fullscreen; the Accessibility API is the fallback |
| Copies on one Steam account can't join each other | The hook gives each copy its own Steam ID and runs Steam lobbies and `ISteamNetworkingMessages` locally between the copies |
| Every game is different | Per-game JavaScript handlers (JavaScriptCore) with options and a `Game.Play(Context)` hook |

## Requirements

- macOS 14 or later (developed on macOS 27, Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`) to build
- Games that are not from the Mac App Store (those are encrypted and can't be hooked)

## Build

```sh
./scripts/build.sh
open build/SofaSplit.app
swift test        # unit tests
```

With only the Command Line Tools installed, `swift test` sometimes fails with
"plugin for module 'TestingMacros' not found". That's an intermittent toolchain issue; run it again.

This produces `build/SofaSplit.app` (GUI, `sofasplit` CLI, and a universal hook for native and Rosetta games)
and `build/TestGame.app`, a diagnostic window that shows what each instance sees.

## Use

1. **Add Game…** and pick the game's `.app` (Steam games are in `~/Library/Application Support/Steam/steamapps/common`).
   A matching handler is chosen automatically, otherwise `Generic.js`.
2. Pick a layout per screen (full, side by side, top/bottom, 3, 4, 6 or 8 players).
3. Press a button on each gamepad to join a slot, or click a slot to assign a pad or the keyboard and mouse.
4. Click **Play**.
5. Connect the copies the way the game does multiplayer: host in player 1, join from the others.

The CLI does the same:

```sh
SS="build/SofaSplit.app/Contents/MacOS/sofasplit"
"$SS" controllers                                   # connected pads and their routing keys
"$SS" play /path/to/Game.app --players 2 --layout sideBySide
"$SS" play build/TestGame.app --players 2           # self-test
```

Ctrl-C (or `kill`) stops every instance.

Data lives in `~/Library/Application Support/SofaSplit/`: `handlers/`, `library.json`, `sofasplit.log`, and
`content/<Game>/Instance<N>/` with the clone, `output.log` and `hook.log` for each player.

## Handlers

Handlers are JavaScript files in `~/Library/Application Support/SofaSplit/handlers/`. Bundled ones are copied
there on first launch and never overwritten afterwards. `Handlers/_Template.js` documents every option and
`Context` helper: per-player arguments and environment, INI/JSON/plist editing, per-instance preferences, files
copied into the clone, an isolated `HOME`, and the Steam app ID. `Handlers/EscapeSimulator2.js` is a complete
real-world example.

### Steam games

- `Game.SteamID`: each clone gets `steam_appid.txt` and the `SteamAppId`/`SteamGameId` environment the Steam client
  sets, so `SteamAPI_RestartAppIfNecessary` doesn't close the clone and relaunch the original.
- `Game.Hook.SteamInput`: for games that read pads through Steam Input. Each instance gets one controller, and its
  lightbar shows the player colour (blue, green, yellow, pink, …).
- `Game.Hook.SteamMultiplayer`: each instance gets its own Steam ID (the "web instance" range, so it never matches
  a real account). Lobbies and `ISteamNetworkingMessages` run between the instances over local Unix sockets. Login,
  game ownership, DLC, achievements, cloud saves and Steam Input still go through the real Steam client. The legacy
  `ISteamNetworking` P2P API and `ISteamNetworkingSockets` aren't emulated yet.

## Limitations

- The game needs some way to connect copies: LAN, direct IP, or Steam lobbies with `SteamMultiplayer`.
  SofaSplit doesn't add multiplayer to single-player games.
- Keyboard and mouse only reach the focused window; macOS can't route a second keyboard to a background app.
- Games that use the hardened runtime are re-signed ad-hoc per clone so the hook can load, which reads the whole
  game once per player.
- Games using exclusive fullscreen (display capture) can't be tiled; run them windowed.
- Steam's "random match" reports no lobbies while `SteamMultiplayer` is on, so the game hosts instead.

## Legal

- SofaSplit is not affiliated with or endorsed by Valve, SplitScreen.Me / Nucleus Co-op, Sony, or any game developer.
  Trademarks belong to their owners.
- The repository contains no game files, no Steamworks SDK files, and no code from Nucleus Co-op. The Steam
  structures it needs for interoperability are declared from scratch.
- SofaSplit doesn't bypass DRM, ownership checks or purchases. You need to own the game and be signed in to Steam,
  which keeps handling login, ownership and DLC. Every copy runs locally on your own Mac.
- Injecting into games and running modified copies may conflict with some games' terms of use. **Don't use it
  with games that have anti-cheat** (Easy Anti-Cheat, BattlEye, VAC-secured servers): that can get an account banned.
- Use at your own risk. This is not legal advice.

## License

[MIT](LICENSE)
