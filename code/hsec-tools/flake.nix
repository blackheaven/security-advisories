{
  description = "hsec-tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          jailbreakUnbreak = pkg:
            pkgs.haskell.lib.doJailbreak (pkgs.haskell.lib.dontCheck (pkgs.haskell.lib.unmarkBroken pkg));

          haskellPackages = pkgs.haskell.packages.ghc925.override
            {
              overrides = hself: hsuper: {
                Cabal-syntax = hsuper.Cabal-syntax_3_8_1_0;
              };
            };

          gitconfig =
            pkgs.writeTextFile {
              name = ".gitconfig";
              text = ''
                [safe]
                  directory = *
              '';
              destination = "/.gitconfig"; # should match 'config.WorkDir'
            };
        in
        rec
        {
          packages.hsec-tools =
            haskellPackages.callCabal2nix "hsec-tools" ./. {
              # Dependency overrides go here
            };
          packages.hsec-tools-image =
            pkgs.dockerTools.buildImage {
              name = "haskell/hsec-tools";
              tag = "latest";

              copyToRoot = pkgs.buildEnv {
                name = "image-root";
                paths = [
                  (pkgs.haskell.lib.justStaticExecutables self.packages.${system}.hsec-tools)
                  pkgs.git.out
                  gitconfig
                ];
                pathsToLink = [ "/bin" "/" ];
              };
              config = {
                Cmd = [ "/bin/hsec-tools" ];
                Env = [
                  "LOCALE_ARCHIVE=${pkgs.glibcLocales}/lib/locale/locale-archive"
                  "LC_TIME=en_US.UTF-8"
                  "LANG=en_US.UTF-8"
                  "LANGUAGE=en"
                  "LC_ALL=en_US.UTF-8"
                  "GIT_DISCOVERY_ACROSS_FILESYSTEM=1"
                ];
                Volumes = {
                  "/advisories" = { };
                };
                WorkDir = "/";
              };
            };

          defaultPackage = packages.hsec-tools;

          devShell =
            pkgs.mkShell {
              buildInputs = with haskellPackages; [
                haskell-language-server
                ghcid
                cabal-install
              ];
              inputsFrom = [
                self.defaultPackage.${system}.env
              ];
            };
        });
}
