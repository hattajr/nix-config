{ pkgs, ... }:

{
  # Tailscale remains a host/system service. These are ordinary OpenSSH
  # connections using the short MagicDNS names supplied by Tailscale.
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    settings = {
      latte = {
        HostName = "latte";
        User = "hattajr";
        Port = 22;
      };

      legion = {
        HostName = "legion";
        User = "hattajr";
        Port = 22;
      };

      # Preserve Home Manager's former defaults explicitly. The wildcard block
      # is emitted after named hosts so OpenSSH's first-value-wins behavior
      # keeps host-specific settings authoritative.
      "*" = {
        ForwardAgent = false;
        AddKeysToAgent = "no";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
    };
  };

  # programs.ssh manages client configuration but does not consistently add
  # the client executable to home.packages across Home Manager versions.
  home.packages = [ pkgs.openssh ];
}
