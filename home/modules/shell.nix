{ lib, pkgs, ... }:

{
  programs.zsh = {
    enable = true;
    enableCompletion = true;

    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    ohMyZsh = {
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
    } // lib.optionalAttrs pkgs.stdenv.isLinux {
      pbcopy = "xclip -selection clipboard";
    };

    initExtra = ''
      setopt AUTO_CD INTERACTIVE_COMMENTS

      PROMPT='%{$fg[green]%}%n@%m%{$reset_color%} %(?:%{$fg[cyan]%}%1{➜%} :%{$fg[red]%}%1{➜%} ) %{$reset_color%}%~ $(git_prompt_info) '

      # tmux helper; tmux itself is configured by the dedicated tmux module.
      t() {
        case "$1" in
          s)
            local name="$2"
            if [ -z "$name" ]; then echo "usage: t s <slug>" >&2; return 1; fi
            if [ -n "$TMUX" ]; then
              tmux has-session -t "$name" 2>/dev/null || tmux new-session -d -s "$name"
              tmux switch-client -t "$name"
            else
              tmux new-session -A -s "$name"
            fi
            ;;
          a)
            local name="$2"
            if [ -z "$name" ]; then echo "usage: t a <slug>" >&2; return 1; fi
            if [ -n "$TMUX" ]; then
              tmux switch-client -t "$name"
            else
              tmux attach-session -t "$name"
            fi
            ;;
          ls) tmux ls ;;
          kda)
            tmux kill-server 2>/dev/null && echo "killed all tmux sessions" || echo "no tmux server running"
            ;;
          *)
            echo "usage: t {s <slug>|a <slug>|ls|kda}" >&2
            return 1
            ;;
        esac
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

  home.sessionPath = [
    "$HOME/bin"
    "$HOME/.config/bin"
    "$HOME/.local/bin"
  ];

  home.sessionVariables = {
    LC_ALL = "en_US.UTF-8";
    TERM = "xterm-256color";
    COLORTERM = "truecolor";
    EDITOR = "nvim";
    VISUAL = "nvim";
    FZF_ALT_C_OPTS = "--walker-skip .git,node_modules,target --preview 'eza --tree --color=always {}'";
    FZF_CTRL_R_OPTS = "--bind 'ctrl-y:execute-silent(echo -n {2..} | pbcopy)+abort' --color header:italic --header 'Press CTRL-Y to copy command into clipboard'";
    FZF_CTRL_T_OPTS = "--walker-skip .git,node_modules,target --preview 'bat -n --color=always {}' --bind 'ctrl-/:change-preview-window(down|hidden|)'";
  };
}
