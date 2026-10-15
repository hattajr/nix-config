{ lib, pkgs, ... }:

let
  version = "0.1.22";
  packageRoot = "lib/node_modules/@playwright/cli";

  # playwright-cli is not packaged by nixpkgs. The npm tarball ships no
  # lockfile, so the committed one pins the exact Playwright prerelease it uses.
  playwrightCli = pkgs.buildNpmPackage {
    pname = "playwright-cli";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@playwright/cli/-/cli-${version}.tgz";
      hash = "sha256-u0hAvhcAbit7qFYiTcMGL2Vx1fZHNSR2+Vxed/9dZ5o=";
    };

    postPatch = ''
      cp ${./playwright-cli-package-lock.json} package-lock.json
    '';

    npmDepsFetcherVersion = 2;
    npmDepsHash = "sha256-r1WYuBDSSmzK68ESJh3Y6q08Hb4GIMheJ9Q94Fvvitc=";
    npmInstallFlags = [ "--omit=dev" ];
    npmFlags = [ "--omit=dev" ];
    dontNpmBuild = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];

    # Nixpkgs' Playwright browser bundle trails the prerelease this CLI pins, so
    # Linux drives the Chromium already installed by packages.nix instead of
    # downloading a second browser. macOS uses its default Chrome channel.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/${packageRoot} $out/bin
      cp -r . $out/${packageRoot}/
      # Fail the build, not activation, if an update moves the entry point or skill.
      test -f $out/${packageRoot}/playwright-cli.js
      test -f $out/${packageRoot}/skills/playwright-cli/SKILL.md
      makeWrapper ${pkgs.nodejs}/bin/node $out/bin/playwright-cli \
        --add-flags $out/${packageRoot}/playwright-cli.js \
        --set-default PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1 ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux
          "--set-default PLAYWRIGHT_MCP_EXECUTABLE_PATH ${pkgs.chromium}/bin/chromium"}
      runHook postInstall
    '';
  };
in
{
  home.packages = [ playwrightCli ];

  # The skill ships inside the package, so linking it from the build keeps the
  # instructions matched to the installed CLI version for both agents.
  home.file = lib.genAttrs [ ".claude/skills/playwright-cli" ".pi/agent/skills/playwright-cli" ]
    (_: {
      source = "${playwrightCli}/${packageRoot}/skills/playwright-cli";
      recursive = true;
      force = true;
    });
}
