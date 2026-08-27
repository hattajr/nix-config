let
  username = "hattajr";
in
{
  aarch64-darwin = {
    system = "aarch64-darwin";
    inherit username;
    homeDirectory = "/Users/${username}";
  };

  aarch64-linux = {
    system = "aarch64-linux";
    inherit username;
    homeDirectory = "/home/${username}";
  };

  x86_64-linux = {
    system = "x86_64-linux";
    inherit username;
    homeDirectory = "/home/${username}";
  };
}
