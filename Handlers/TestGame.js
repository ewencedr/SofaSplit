// Handler for the bundled diagnostic app (build/TestGame.app).
// Each instance shows what it sees: its bundle id, focus state, window frame and gamepads.
Game.GameName = "SofaSplit Test Game";
Game.GUID = "SofaSplitTestGame";
Game.ExecutableName = "TestGame.app";
Game.MaxPlayers = 8;
Game.Description = "Diagnostic window: verifies cloning, gamepad routing, force focus and window placement.";
Game.PauseBetweenStarts = 500;
Game.IsolateHome = true;

Game.Play = function (Context) {
  Context.Environment["TESTGAME_STATUS"] = Context.InstanceRoot + "/status.json";
  Context.StartArguments = "--player " + Context.PlayerNumber;
  Context.SetDefault("PlayerName", "Player " + Context.PlayerNumber);
  Context.Log("prepared at " + Context.Width + "x" + Context.Height);
};
