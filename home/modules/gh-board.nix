{ pkgs, ... }:

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
in
{
  home.packages = [ gh-board ];
}
