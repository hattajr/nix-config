{ lib, pkgs, ... }:

let
  # Pi is not currently packaged by nixpkgs. Build the published package with
  # its lockfile and keep the application version pinned independently of the
  # rest of the Nix channel.
  piPackage = pkgs.buildNpmPackage {
    pname = "pi-coding-agent";
    version = "0.84.2";

    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-0.84.2.tgz";
      hash = "sha256-lbiZzXsaDB8BdMe/M6tCdDXjVTp9H0dWZhqpx/Gmj/o=";
    };

    # The published shrinkwrap omits integrity metadata for Pi's six sibling
    # packages. Add the registry-published values before Nix prefetches npm
    # dependencies; the package is otherwise unchanged.
    postPatch = ''
      sed -i '78,89d' package.json
      sed -i '/pi-agent-core-0.84.2.tgz/ a\
          "integrity": "sha512-8Pn3wSCxj0cfo5I6jxQYVB/3uuQRmHhAlEclyjqpOuMEdQMIODHizRogv56FLdbU+dTiGnybeHQ2N+sV1/L2YA==",' npm-shrinkwrap.json
      sed -i '/pi-ai-0.84.2.tgz/ a\
          "integrity": "sha512-6MzsrYIYNVlE7SfpbL2yYb67Qo58p/7Q+xWG1RZvoX1P80aRCHSod2/13aFpxkow1lPO2LEh3c495J0Gwmyjig==",' npm-shrinkwrap.json
      sed -i '/pi-client-0.84.2.tgz/ a\
          "integrity": "sha512-/RFSPhD/bZbpOp1oJj+UneSUFSgZhWxzcSENUY+8+8xhoBrWXMYI2t77XNx4Yf+c8YK2qTHquForhNcelYpXvg==",' npm-shrinkwrap.json
      sed -i '/pi-protocol-0.84.2.tgz/ a\
          "integrity": "sha512-jbBh03fkeckWEroHpcZBr4w5/Ibat8WwdXFlXHivYQImrQNFtLpDeL0t1cku4hmK0q3pceIRQHkw4fwbM4YILQ==",' npm-shrinkwrap.json
      sed -i '/pi-telemetry-0.84.2.tgz/ a\
          "integrity": "sha512-wg5caea7uIv1BHRBm2Y116RvFG4oSAiP5qk9tA2463PDGIr4K8M1Ceyyg5DOpF/shUUl0gk826yQJAeAcHYB9g==",' npm-shrinkwrap.json
      sed -i '/pi-tui-0.84.2.tgz/ a\
          "integrity": "sha512-ds2TLihOnM5sLJB3VpXV6y0uR5efVuHf4MN7yDpsty6hA2DUO/EDVzjp/0od0G2JslzVLMjT8T8zavtxVb+qbg==",' npm-shrinkwrap.json
    '';

    npmDepsFetcherVersion = 2;
    npmDepsHash = "sha256-QUkW5vMhKDPn947/BJ1Bslry1Kl2bQsO8j5tNmY1oNc=";
    npmInstallFlags = [ "--omit=dev" ];
    npmFlags = [ "--omit=dev" ];
    dontNpmBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/node_modules/@earendil-works/pi-coding-agent
      cp -r . $out/lib/node_modules/@earendil-works/pi-coding-agent/
      mkdir -p $out/bin
      ln -s $out/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js $out/bin/pi
      runHook postInstall
    '';
  };

  piSettings = ../../config/pi/agent/settings.json;
  piStaticRoot = ../../config/pi/agent;
  # Never link an entire Pi directory: Pi keeps sessions, OAuth, npm state, and
  # locally installed extensions below the same writable parents.  Each static
  # reference file is instead linked independently.
  piStaticFiles = builtins.filter (source: toString source != toString piSettings)
    (lib.filesystem.listFilesRecursive piStaticRoot);
  piStaticHomeFiles = builtins.listToAttrs (map (source: {
    name = ".pi/agent/${lib.removePrefix "${toString piStaticRoot}/" (toString source)}";
    value = { inherit source; force = true; };
  }) piStaticFiles);
in
{
  home.packages = [ piPackage ];

  home.activation.piSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    settings="$HOME/.pi/agent/settings.json"
    temporary="$settings.tmp.$$"
    mkdir -p "$(dirname "$settings")"

    # Preserve Pi's live changelog marker while refreshing managed settings
    # without leaving the runtime file as a read-only /nix/store symlink.
    last_changelog_version="0.0.0"
    if [ -f "$settings" ]; then
      last_changelog_version="$(${pkgs.jq}/bin/jq -r '.lastChangelogVersion // "0.0.0"' "$settings" 2>/dev/null || printf '%s' '0.0.0')"
    fi
    ${pkgs.jq}/bin/jq --arg version "$last_changelog_version" \
      '.lastChangelogVersion = $version' "${piSettings}" > "$temporary"
    chmod 0644 "$temporary"
    mv -f "$temporary" "$settings"
  '';

  home.file = piStaticHomeFiles // {
    ".pi/README.md" = { source = ../../config/pi/README.md; force = true; };
    ".pi/.gitignore" = { source = ../../config/pi/.gitignore; force = true; };
    ".pi/.nvmrc" = { source = ../../config/pi/.nvmrc; force = true; };
    ".local/bin/pi" = {
      source = ../../bin/pi;
      executable = true;
      force = true;
    };
    ".local/bin/proton-pass-pi-env" = {
      source = ../../bin/proton-pass-pi-env;
      executable = true;
      force = true;
    };
    ".pi/.claude/settings.local.json" = { source = ../../config/pi/.claude/settings.local.json; force = true; };
    ".claude/settings.local.json" = { source = ../../config/claude/settings.local.json; force = true; };
  };
}
