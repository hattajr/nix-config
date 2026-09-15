# User PATH entries that precede the Nix profile, highest precedence first.
#
# The shell module builds home.sessionPath from this list and the shadowed
# binary checker scans exactly these directories, so a report can never
# disagree with the PATH an interactive shell actually receives.
[
  "$HOME/bin"
  "$HOME/.config/bin"
  "$HOME/.local/bin"
]
