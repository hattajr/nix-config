let
  environmentOr = name: fallback:
    let value = builtins.getEnv name;
    in if value == "" then fallback else value;
  username = environmentOr "NIX_CONFIG_USERNAME" (builtins.getEnv "USER");
  homeDirectory = environmentOr "NIX_CONFIG_HOME" (builtins.getEnv "HOME");
in
{
  aarch64-darwin = {
    system = "aarch64-darwin";
    inherit username homeDirectory;
  };

  aarch64-linux = {
    system = "aarch64-linux";
    inherit username homeDirectory;
  };

  x86_64-linux = {
    system = "x86_64-linux";
    inherit username homeDirectory;
  };
}
