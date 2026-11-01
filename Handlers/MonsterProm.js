// Monster Prom (Steam, Unity 2017). Has its own local multiplayer on one screen: play it with the
// "Shared screen" layout, so one window sees every controller.
Game.GameName = "Monster Prom";
Game.GUID = "MonsterProm";
Game.ExecutableName = "MonsterProm.app";
Game.BundleIdentifier = "com.beautifulglitch.MonsterProm";
Game.SteamID = "743450";
Game.MaxPlayers = 4;
Game.DefaultLayout = "shared";  // one window that sees every controller
Game.Description = "Local multiplayer for up to 4 players in one window: every controller plays in the shared screen.";

Game.CloneGame = true;
Game.ChangeBundleID = false;  // the save games are stored under the bundle ID: keep the player's own
Game.PauseBetweenStarts = 1000;

Game.Hook.Inject = true;
Game.Hook.ForceFocus = true;
Game.Hook.Borderless = true;
// The game only knows the Xbox 360 controller as the old macOS driver numbered it (A = button 16, B = 17, …),
// and reads controllers through Unity's old input system, which can't read a DUALSHOCK 4 on Bluetooth.
Game.Hook.PlayStationBluetooth = true;
Game.Hook.ControllerLayout = "xbox360";

Game.Play = function (Context) {
  Context.StartArguments = "-screen-fullscreen 0 -screen-width " + Context.PixelWidth +
                           " -screen-height " + Context.PixelHeight +
                           " -logFile '" + Context.InstanceRoot + "/Player.log'";  // own log per player
};
