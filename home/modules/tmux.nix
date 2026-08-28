{ config, pkgs, ... }:

let
  # Dracula resolves custom widgets relative to its own scripts directory. Keep
  # our shortcut widget inside the immutable plugin package so it works both
  # through Home Manager and in a freshly started tmux server.
  draculaWithKeys = pkgs.tmuxPlugins.dracula.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cp ${../../config/tmux/keys.sh} "$out/share/tmux-plugins/dracula/scripts/keys.sh"
      chmod +x "$out/share/tmux-plugins/dracula/scripts/keys.sh"
    '';
  });
in
{
  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    historyLimit = 50000;
    mouse = true;
    keyMode = "vi";
    prefix = "C-Space";
    escapeTime = 0;
    baseIndex = 1;

    plugins = with pkgs.tmuxPlugins; [
      sensible
      {
        plugin = draculaWithKeys;
        # Home Manager runs plugin configuration immediately before the plugin.
        # Dracula must see these settings before its startup script builds the
        # status line.
        extraConfig = ''
          set -g @dracula-plugins "custom:keys.sh git cpu-usage ram-usage"
          set -g @dracula-custom-plugin-colors "gray white"
          set -g @dracula-show-left-icon "#h:#S"
          set-option -g renumber-windows on
        '';
      }
    ];

    extraConfig = ''
      # Preserve terminal capabilities used by Neovim and terminal TUIs.
      set -g allow-passthrough on
      set -ga terminal-overrides ",*256col*:Tc"
      set -s extended-keys on
      set -g extended-keys-format csi-u
      set -as terminal-features 'xterm*:extkeys'
      set -ga terminal-overrides '*:Ss=\E[%p1%d q:Se=\E[ q'
      set-environment -g COLORTERM "truecolor"

      # Prefix and repeatable pane controls.
      unbind C-b
      bind C-Space send-prefix
      set -g repeat-time 2500

      bind '"' split-window -v -c "#{pane_current_path}"
      bind % split-window -h -c "#{pane_current_path}"

      # Generic tmux clipboard forwarding over supported terminals and SSH.
      set -g set-clipboard on
      set -ga terminal-features ",xterm*:clipboard"
      set -g mouse on

      # Preserve alternate-screen behavior while scrolling.
      bind -n WheelUpPane if-shell -F "#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}" "send-keys -M" "copy-mode -e"
      bind -n WheelDownPane select-pane -t= \; send-keys -M
      bind -n C-WheelUpPane select-pane -t= \; copy-mode -e \; send-keys -M
      bind -T copy-mode-vi WheelUpPane send-keys -X -N 3 scroll-up
      bind -T copy-mode-vi WheelDownPane send-keys -X -N 3 scroll-down
      bind -T copy-mode-vi C-WheelUpPane send-keys -X halfpage-up
      bind -T copy-mode-vi C-WheelDownPane send-keys -X halfpage-down
      bind -T copy-mode-emacs C-WheelUpPane send-keys -X halfpage-up
      bind -T copy-mode-emacs C-WheelDownPane send-keys -X halfpage-down
      unbind -T copy-mode-vi Enter
      bind-key -T copy-mode-vi Enter send-keys -X copy-selection-and-cancel
      bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection-and-cancel

      # Vim-like pane resizing and selection.
      bind -r K resize-pane -U
      bind -r J resize-pane -D
      bind -r H resize-pane -L
      bind -r L resize-pane -R
      unbind k
      unbind j
      unbind h
      unbind l
      bind k select-pane -U
      bind j select-pane -D
      bind h select-pane -L
      bind l select-pane -R

      set -g status on
      unbind Up
      unbind Down
      unbind Left
      unbind Right
      unbind C-Up
      unbind C-Down
      unbind C-Left
      unbind C-Right

      set -g window-style 'bg=#21222c,fg=#808080'
      set -g window-active-style 'bg=#282a36,fg=#f8f8f2'

      # Match tmux's bracketed-paste behavior for terminal TUIs.
      bind ] paste-buffer -p
      bind -n MouseDown2Pane select-pane -t = \; if -F "#{||:#{pane_in_mode},#{mouse_any_flag}}" { send-keys -M } { paste-buffer -p }
      set -g pane-active-border-style 'fg=#50fa7b,bold'
      set -g pane-border-style 'fg=#44475a'
    '';
  };

  xdg.configFile."tmux/keys.sh" = {
    source = ../../config/tmux/keys.sh;
    executable = true;
  };
}
