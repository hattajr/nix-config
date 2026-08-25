{ ... }:

{
  # Shared, non-secret user files. Package ownership stays in the package
  # module; these declarations only install configuration and helpers.
  xdg.configFile."bottom/bottom.toml".source = ../../config/bottom/bottom.toml;
  home.file.".inputrc".source = ../../config/inputrc;

  home.file.".local/bin/devtunnel" = {
    source = ../../bin/devtunnel;
    executable = true;
  };

  home.file.".local/bin/pi-models-sync" = {
    source = ../../bin/pi-models-sync;
    executable = true;
  };
}
