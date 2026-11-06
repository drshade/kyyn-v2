{
  description = "Kyyn host and contributor toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      project = system:
        let
          pkgs = import nixpkgs { inherit system; };
          localPackages = {
            kyyn-types = "shared/kyyn-types";
            kyyn-domain = "host/kyyn-domain";
            kyyn-plumbing = "host/kyyn-plumbing";
            kyyn-microhs = "host/kyyn-microhs";
            kyyn-plumbing-interpreters = "host/kyyn-plumbing-interpreters";
            kyyn-porcelain = "host/kyyn-porcelain";
            kyyn-porcelain-interpreters = "host/kyyn-porcelain-interpreters";
            kyyn-surfaces = "host/kyyn-surfaces";
            kyyn = "host/kyyn";
            kyyn-sdk = "guest/kyyn-sdk";
            json = "vendor/json";
            agentic = "vendor/agentic";
            agentic-aeson = "vendor/agentic-aeson";
            agentic-openai = "vendor/agentic-openai";
            agentic-anthropic = "vendor/agentic-anthropic";
            agentic-jev = "vendor/agentic-jev";
          };
          haskell = pkgs.haskell.packages.ghc9103.override {
            overrides = final: prev:
              let
                pinned = {
                  aeson = "2.2.5.0";
                  effectful-core = "2.6.1.0";
                  dhall = "1.42.3";
                  http-client = "0.7.19";
                  http-types = "0.12.5";
                  optparse-applicative = "0.19.0.0";
                  random = "1.3.1";
                  typed-process = "0.2.13.0";
                };
              in
              builtins.mapAttrs (name: version: final.callHackage name version { }) pinned
              // builtins.mapAttrs (name: path:
                pkgs.haskell.lib.overrideCabal
                  (final.callCabal2nix name (self + "/${path}") { })
                  (_: {
                    # Some packages share source and guide files across directories.
                    src = self;
                    postUnpack = ''sourceRoot="$sourceRoot/${path}"'';
                    doCheck = false;
                  })) localPackages;
          };
        in {
          inherit pkgs haskell localPackages;
        };
    in {
      packages = forAllSystems (system:
        let p = project system;
        in {
          kyyn = p.haskell.kyyn;
          default = self.packages.${system}.kyyn;
        });
      devShells = forAllSystems (system:
        let p = project system;
        in {
          default = p.haskell.shellFor {
            packages = h: map (name: h.${name}) (builtins.attrNames p.localPackages);
            nativeBuildInputs = with p.pkgs; [ cabal-install nodejs_22 git gnumake pkg-config ];
          };
        });
    };
}
