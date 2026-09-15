{ lib, pkgs, ... }:

let
  # Shared with the shadowed-binary checker so a report can never disagree
  # with the PATH an interactive shell actually receives.
  precedingPathDirs = import ../../lib/path-dirs.nix;
in
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autocd = true;
    setOptions = [ "INTERACTIVE_COMMENTS" ];

    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";
      plugins = [ "git" ];
    };

    history = {
      size = 10000;
      save = 10000;
      path = "$HOME/.zsh_history";
      ignoreDups = true;
      ignoreSpace = true;
      extended = true;
      share = true;
    };

    shellAliases = {
      ls = "eza";
      la = "eza --long --all --group";
      cat = "bat";
      lzg = "lazygit";
      n = "nvim";
      dbui = "nvim -c 'Lazy load vim-dadbod-ui' -c DBUI";
      lzd = "lazydocker";
    } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      pbcopy = "xclip -selection clipboard";
    };

    initContent = ''
      PROMPT='%{$fg[green]%}%n@%m%{$reset_color%} %(?:%{$fg[cyan]%}%1{➜%} :%{$fg[red]%}%1{➜%} ) %{$reset_color%}%~ $(git_prompt_info) '

      # `t` opens or reattaches a session named after the current directory,
      # so each project keeps one stable session. `tmux` itself is untouched.
      t() {
        local name="''${PWD##*/}"
        # tmux treats "." and ":" as session/window/pane separators.
        name="''${name//[.:]/_}"
        [ -z "$name" ] && name="root"

        # "=" forces an exact match; a bare name also matches by prefix.
        if tmux has-session -t "=$name" 2>/dev/null; then
          if [ -n "$TMUX" ]; then
            tmux switch-client -t "=$name"
          else
            tmux attach-session -t "=$name"
          fi
        else
          if [ -n "$TMUX" ]; then
            tmux new-session -d -s "$name" -c "$PWD"
            tmux switch-client -t "=$name"
          else
            tmux new-session -s "$name" -c "$PWD"
          fi
        fi
      }

      # Serve a directory over HTTP on the LAN using the Nix-provided uv.
      serve() {
        if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
          cat >&2 <<'EOF'
      serve - publish a directory over HTTP on the LAN (binds 0.0.0.0)
      usage: serve [dir] [port]
        serve            serve cwd on port 8083
        serve ./public   serve ./public on port 8083
        serve . 9000     serve cwd on port 9000
      Prints the Tailscale IP (or LAN IP) it's reachable on.
      EOF
          return 0
        fi
        local dir="''${1:-.}"
        local port="''${2:-8083}"
        local ip
        ip="$(tailscale ip -4 2>/dev/null | head -n1)"
        [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        echo "serving $dir on http://''${ip:-0.0.0.0}:$port (Ctrl-C to stop)"
        uv run python -m http.server "$port" --bind 0.0.0.0 --directory "$dir"
      }
    '';
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # zsh never reads ~/.profile, where the Nix installer puts its hook, so the
  # profile is appended here. It deliberately ranks below the directories that
  # hold Home Manager's own wrappers; the bro menu reports unmanaged
  # binaries that exploit that ordering to shadow a managed package.
  home.sessionPath = precedingPathDirs ++ [ "$HOME/.nix-profile/bin" ];

  home.sessionVariables = {
    COLORTERM = "truecolor";
    EDITOR = "nvim";
    VISUAL = "nvim";
    FZF_ALT_C_OPTS = "--walker-skip .git,node_modules,target --preview 'eza --tree --color=always {}'";
    FZF_CTRL_R_OPTS = "--bind 'ctrl-y:execute-silent(echo -n {2..} | pbcopy)+abort' --color header:italic --header 'Press CTRL-Y to copy command into clipboard'";
    FZF_CTRL_T_OPTS = "--walker-skip .git,node_modules,target --preview 'bat -n --color=always {}' --bind 'ctrl-/:change-preview-window(down|hidden|)'";
  };
}
