# Which background jobs a machine runs is per-machine state that bro passes to
# mkHome, never committed configuration, so every committed output runs none.
{ config, lib, pkgs, ... }:

{
  options.nixConfig.backgroundJobs = lib.mkOption {
    type = lib.types.listOf (lib.types.enum [ "board-sync" ]);
    default = [ ];
    description = "Background jobs enabled on this machine from bro's Jobs menu.";
  };

  config.assertions = [
    {
      assertion = config.nixConfig.backgroundJobs == [ ] || pkgs.stdenv.hostPlatform.isLinux;
      message = "background jobs run as systemd user timers, so they are only supported on Linux";
    }
  ];
}
