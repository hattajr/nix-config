{ pkgs, ... }:

let
  # The Chezmoi setup builds Neovim from source. Select nixpkgs' unwrapped
  # source-built package explicitly; Home Manager may add its normal provider
  # wrapper around this package when provider support is enabled.
  neovimSource = pkgs.neovim-unwrapped;
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
  home.file.".local/bin/vi".source = "${neovimSource}/bin/nvim";
  home.file.".local/bin/vim".source = "${neovimSource}/bin/nvim";

  # Keep the LazyVim source tree in Git while allowing Neovim's mutable state
  # and downloaded plugins to live under XDG_DATA_HOME.
  xdg.configFile."nvim".source = ../../config/nvim;

  # Dependencies used directly by the configuration or by editor tooling.
  # General CLI tools (git, fd, ripgrep, lazygit, node, etc.) remain in the
  # shared package module rather than being duplicated here.
  home.packages = with pkgs; [
    lua-language-server
    stylua
    tree-sitter
  ];
}
