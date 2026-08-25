{ pkgs, ... }:

{
  # Tailscale remains a host/system service. These are ordinary OpenSSH
  # connections using the short MagicDNS names supplied by Tailscale.
  programs.ssh = {
    enable = true;

    matchBlocks = {
      latte = {
        hostname = "latte";
        user = "hattajr";
        port = 22;
      };

      legion = {
        hostname = "legion";
        user = "hattajr";
        port = 22;
      };
    };
  };

  # programs.ssh manages client configuration but does not consistently add
  # the client executable to home.packages across Home Manager versions.
  home.packages = [ pkgs.openssh ];
}
