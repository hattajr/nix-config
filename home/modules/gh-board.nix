{ config, lib, pkgs, ... }:

let
  gh-board = pkgs.writeShellApplication {
    name = "gh-board";
    runtimeInputs = [
      pkgs.gawk
      pkgs.gh
      pkgs.gnugrep
      pkgs.jq
    ];
    text = builtins.readFile ../../bin/gh-board;
  };

  boardSyncEnabled = builtins.elem "board-sync" config.nixConfig.backgroundJobs;
in
{
  home.packages = [ gh-board ];

  # gh-board only ever adds, so several machines enabling this at once is
  # harmless. A run missed while no session was running happens when the user
  # manager next starts: at login, or at boot with lingering enabled.
  systemd.user = lib.mkIf boardSyncEnabled {
    services.gh-board-sync = {
      Unit.Description = "Add my open GitHub issues to my project boards";
      Service = {
        Type = "oneshot";
        # Without a limit a hung gh would block every later run of the timer.
        TimeoutStartSec = "15min";
        ExecStart = "${lib.getExe gh-board} sync";
      };
    };
    timers.gh-board-sync = {
      Unit.Description = "Hourly GitHub board sync";
      Timer = {
        OnCalendar = "hourly";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
