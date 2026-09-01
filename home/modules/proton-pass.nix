{ ... }:

{
  # Only non-secret reference examples are declarative. The operational
  # pi.env and every application session remain writable local runtime state.
  home.file = {
    ".config/proton-pass/pi.env.example" = { source = ../../config/proton-pass/pi.env.example; force = true; };
    ".config/proton-pass/README.md" = { source = ../../config/proton-pass/README.md; force = true; };
    ".config/proton-pass/references.md" = { source = ../../config/proton-pass/references.md; force = true; };

    ".local/bin/nix-config-setup" = {
      source = ../../bin/nix-config-setup;
      executable = true;
      force = true;
    };
    ".local/bin/proton-pass-session" = {
      source = ../../bin/proton-pass-session;
      executable = true;
      force = true;
    };
  };
}
