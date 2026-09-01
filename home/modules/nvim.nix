{ lib, pkgs, ... }:

let
  # Select nixpkgs' unwrapped Neovim package explicitly. Home Manager may add
  # source-built package explicitly; Home Manager may add its normal provider
  # wrapper around this package when provider support is enabled.
  neovimSource = pkgs.neovim-unwrapped;
  nvimConfigRoot = ../../config/nvim;
  # Link leaves individually so existing ~/.config/nvim remains a real
  # directory. Forced ownership replaces only declared files and preserves
  # unrelated local entries.
  nvimConfigFiles = lib.filesystem.listFilesRecursive nvimConfigRoot;
  nvimConfigHomeFiles = builtins.listToAttrs (map (source: {
    name = "nvim/${lib.removePrefix "${toString nvimConfigRoot}/" (toString source)}";
    value = { inherit source; force = true; };
  }) nvimConfigFiles);
in
{
  programs.neovim = {
    enable = true;
    package = neovimSource;
    defaultEditor = true;
    viAlias = false;
    vimAlias = false;
    withPython3 = false;
    withRuby = false;
  };

  # Preserve the historical vi/vim command names without invoking the
  # nixpkgs Neovim wrapper or generating a mutable remote-plugin manifest.
  home.file.".local/bin/vi" = { source = "${neovimSource}/bin/nvim"; force = true; };
  home.file.".local/bin/vim" = { source = "${neovimSource}/bin/nvim"; force = true; };

  # Keep the LazyVim source tree in Git while allowing Neovim's mutable state
  # and downloaded plugins to live under XDG_DATA_HOME. Per-leaf links preserve
  # unrelated files in an existing ~/.config/nvim tree.
  xdg.configFile = nvimConfigHomeFiles;

  # Lazy must write its operational lockfile, while the versioned source is a
  # read-only Nix-store symlink. Seed a regular state copy on activation. A
  # baseline lets repository updates propagate unless Lazy changed the state
  # copy locally, in which case the user's operational lock is preserved.
  home.activation.nvimLockfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    state_home="''${XDG_STATE_HOME:-$HOME/.local/state}"
    lock_dir="$state_home/nvim/lazy"
    lockfile="$lock_dir/lazy-lock.json"
    baseline="$lock_dir/managed-lazy-lock.json"
    temporary="$lock_dir/lazy-lock.json.tmp.$$"
    baseline_temporary="$lock_dir/managed-lazy-lock.json.tmp.$$"
    mkdir -p "$lock_dir"

    if [ ! -f "$lockfile" ] || [ -L "$lockfile" ] \
      || { [ -f "$baseline" ] && ${pkgs.diffutils}/bin/cmp -s "$lockfile" "$baseline"; }; then
      cp ${../../config/nvim/lazy-lock.json} "$temporary"
      chmod 0644 "$temporary"
      mv -f "$temporary" "$lockfile"
    fi

    cp ${../../config/nvim/lazy-lock.json} "$baseline_temporary"
    chmod 0644 "$baseline_temporary"
    mv -f "$baseline_temporary" "$baseline"
  '';

  # Dependencies used directly by the configuration or by editor tooling.
  # General CLI tools (git, fd, ripgrep, lazygit, node, etc.) remain in the
  # shared package module rather than being duplicated here.
  home.packages = with pkgs; [
    lua-language-server
    stylua
    tree-sitter
  ];
}
