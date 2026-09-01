{ ... }:

{
  # Prefer Home Manager's native application modules when they can represent
  # the complete configuration. Home Manager also owns these packages.
  programs.bottom = {
    enable = true;
    settings = {
      flags = { };
      row = [
        { child = [ { type = "cpu"; } ]; }
        { child = [ { type = "mem"; } ]; }
        { child = [ { type = "proc"; default = true; } ]; }
      ];
    };
  };

  programs.readline = {
    enable = true;
    variables.enable-bracketed-paste = "on";
  };

  home.file.".local/bin/bro" = {
    source = ../../bin/bro;
    executable = true;
    force = true;
  };

  home.file.".local/bin/devtunnel" = {
    source = ../../bin/devtunnel;
    executable = true;
    force = true;
  };

  home.file.".local/bin/pi-models-sync" = {
    source = ../../bin/pi-models-sync;
    executable = true;
    force = true;
  };
}
