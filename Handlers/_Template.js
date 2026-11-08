// SofaSplit — handler template.
// Copy this file (without the leading underscore) into the handlers folder:
//   ~/Library/Application Support/SofaSplit/handlers/
// and adjust it for your game. Every option is optional; defaults are shown.

Game.GameName = "My Game";            // Name shown in the UI.
Game.GUID = "MyGame";                 // Folder name for this game's instances (letters/digits only).
Game.ExecutableName = "My Game.app";  // Used to auto-pick this handler: the .app name or its inner executable name.
Game.BundleIdentifier = "";           // Alternative match: the app's CFBundleIdentifier.
Game.MaxPlayers = 4;                  // Informational; a warning is logged if you launch more.
Game.Description = "Host a LAN game in player 1, join it from the others.";  // Shown under the title.

// ---- Instances -------------------------------------------------------------
Game.CloneGame = true;        // Make an APFS clone of the .app per player (no extra disk space). Needed for hooks.
Game.ChangeBundleID = true;   // Give each clone its own bundle id (<id>.sofasplit<N>): defeats single-instance
                              // checks and separates each player's preferences (~/Library/Preferences/<id>.plist).
Game.IsolateHome = false;     // Give each instance its own HOME (saves, Application Support, Documents…).
Game.HomeSymlinks = [];       // With IsolateHome: paths linked to the real home, e.g. ["Library/Application Support/Steam"].
Game.HomeCopies = [];         // With IsolateHome: paths copied once from the real home to seed each player (saves, settings).
Game.PauseBetweenStarts = 1500;   // Milliseconds between instance launches.
Game.MinAspectRatio = "";         // e.g. "4:3" or "16:9": a slot narrower than this (side by side is almost square)
                                  // gets a shorter window, centred with black bars, for games that refuse or crop
                                  // narrow windows. "" fills the slot. All sizes below are the fitted window's.
Game.StartArguments = "";         // e.g. "-screen-width %PIXELWIDTH% -screen-height %PIXELHEIGHT% -screen-fullscreen 0"
                                  // Variables: %PLAYER% %PLAYERID% %WIDTH% %HEIGHT% %PIXELWIDTH% %PIXELHEIGHT% %X% %Y% %INSTANCE%
Game.Executable = "";             // Binary to start, relative to the .app (default: its CFBundleExecutable), e.g.
                                  // "Contents/MacOS/Game" to skip a publisher's launcher.
Game.WorkingFolder = "";          // Relative to the .app (default: Contents/MacOS).
Game.SteamID = "";                // Writes steam_appid.txt into each clone's working folder.
Game.Environment = {};            // Extra environment variables for every instance.
Game.CopyFiles = [];              // ["files/steam_api.dylib -> Contents/Frameworks/libsteam_api.dylib"] (source is relative to the handlers folder)
Game.DeleteFiles = [];            // ["Contents/Resources/intro.mov"] relative to the clone.

// ---- Hooks (libSofaSplitHook.dylib, injected with DYLD_INSERT_LIBRARIES) -----
Game.DefaultLayout = "";              // Layout picked when the game is selected, e.g. "shared" for local co-op games
Game.Hook.Inject = true;              // Master switch. Mac App Store (FairPlay-encrypted) games must use false.
Game.Hook.GamepadRouting = true;      // Each instance only sees the gamepad assigned to it.
Game.Hook.SteamInput = false;         // Game reads pads via Steam Input: route Steam controller handles, hide raw HID pads.
                                      // Each routed pad lights up in its player colour (P1 blue, P2 green, P3 yellow, P4 pink).
Game.Hook.SteamMultiplayer = false;   // Steam lobby/P2P games: give each instance its own Steam identity and run
                                      // lobbies, the lobby list, ISteamNetworkingMessages and legacy ISteamNetworking
                                      // P2P locally between the instances (real Steam still handles login, DLC,
                                      // Steam Input, achievements).
Game.Hook.ForceFocus = true;          // Instances keep running/reading input while in the background.
Game.Hook.PlayStationBluetooth = true; // Decode Bluetooth DUALSHOCK 4 input for games that read HID elements (Unity's
                                      // old input system), which otherwise see the pad but never get a button press.
Game.Hook.LegacyControllerNames = false; // Report a DUALSHOCK 4 by its pre-2020 macOS name, for input libraries
                                      // (old InControl) that only know that name.
Game.Hook.ControllerLayout = "";      // "xbox360": number a DUALSHOCK 4's buttons like an Xbox 360 controller under
                                      // the old macOS driver (A = 16, B = 17, X = 18, Y = 19, Start = 9, d-pad 5-8),
                                      // for games that hard-code that layout.
Game.Hook.SharedUDPPorts = "";        // LAN games: UDP ports every instance may bind, comma-separated, so the copies
                                      // see each other's LAN games (Unreal Engine 3: "14001"). Only list discovery
                                      // ports, never the game's own traffic port.
Game.Hook.UnhideSteamInputPads = false; // SDL games: with Steam Input on, Steam hides the real pads from SDL and
                                      // expects a virtual pad macOS doesn't have, so the game sees none. true keeps them.
Game.Hook.Borderless = true;          // Remove the title bar from the game window.
Game.Hook.WindowPositioning = "auto"; // "auto" (hook, or Accessibility when not injected) | "hook" | "accessibility" | "none"

// ---- Per-instance script ---------------------------------------------------
// Called once per player, before that instance starts. `Context` is also available as a global.
Game.Play = function (Context) {
  // Read-only info:
  //   Context.PlayerID (0-based), Context.PlayerNumber, Context.PlayersCount
  //   Context.Width, Context.Height (points), Context.PixelWidth, Context.PixelHeight, Context.PosX, Context.PosY
  //   Context.InstanceRoot, Context.InstanceFolder (the cloned .app), Context.HomeFolder, Context.BundleIdentifier
  //   Context.IsKeyboardPlayer
  // Writable:
  //   Context.StartArguments, Context.Environment
  // Helpers (relative paths resolve against Context.InstanceRoot, "~" works):
  //   Context.Log(msg), Context.GetFolder(SofaSplit.Folder.AppSupport), Context.FileExists(p)
  //   Context.ReadFile(p), Context.WriteFile(p, text), Context.MakeDir(p), Context.DeleteFile(p)
  //   Context.CopyFile(fromRelativeToHandlers, to), Context.ReplaceInFile(p, regex, replacement)
  //   Context.ModifyIni(p, section, key, value), Context.SetPlistValue(p, "Key.Sub", value)
  //   Context.ModifyJson(p, "key.sub", value)
  //   Context.SetDefault(key, value)  -> this instance's preferences domain

  // Example: Unity games read their window size from command line arguments.
  // Context.StartArguments += " -screen-width " + Context.PixelWidth + " -screen-height " + Context.PixelHeight;

  // Example: per-player nickname in an ini file inside the clone.
  // Context.ModifyIni(Context.InstanceFolder + "/Contents/Resources/settings.ini", "Player", "Name", "Player" + Context.PlayerNumber);
};
