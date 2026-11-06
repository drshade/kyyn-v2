{
  description = "Kyyn host and contributor toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.agentic = {
    url = "github:drshade/haskell-agentic/043604a28ceb7d2ebba0921856b719b5f5d661b3";
    flake = false;
  };

  outputs = { self, nixpkgs, agentic }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      project = system:
        let
          pkgs = import nixpkgs { inherit system; };
          source = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./host ./guest ./shared ./plugins ./vendor ./docs/guide.md
            ];
          };
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
            kyyn-guest-build = "guest/kyyn-build";
          };
          haskell = pkgs.haskell.packages.ghc9103.override {
            overrides = final: prev:
              let
                pinned = {
                  filelock = { version = "0.1.1.8"; hash = "sha256-0qNcgMmZ6pl7oEUPROuuDo4MKoKzVGlrqBAfjoS5yvo="; };
                  aeson = { version = "2.2.5.0"; hash = "sha256-RooTSc8dZrcUiWFQDssKv1/l5OB/psUD7jbyWG/7VKQ="; };
                  effectful-core = { version = "2.6.1.0"; hash = "sha256-0UTeE7JnUkNx77QobyjKjQFpUVQsz6a1E55WEohJ+hI="; };
                  dhall = { version = "1.42.3"; hash = "sha256-/yOhbmlljlo8bpvlOCBQS0n6HbqcDy4DtIIwLShYlxE="; };
                  http-client = { version = "0.7.19"; hash = "sha256-KY6XuRBqlpGdsxEOs9mbIhkoOobuAEmdSSrMqBh9keE="; };
                  http-types = { version = "0.12.5"; hash = "sha256-Y1/wrRFPIVxgTGWgPboRDUht+fzvl3e1jazj+G1pTw0="; };
                  optparse-applicative = { version = "0.19.0.0"; hash = "sha256-dhqvRILfdbpYPMxC+WpAyO0KUfq2nLopGk1NdSN2SDM="; };
                  random = { version = "1.3.1"; hash = "sha256-M2xVhHMZ7Lqvx/F832mGirHULgzv7TjP/oNkQ4V6YLM="; };
                  typed-process = { version = "0.2.13.0"; hash = "sha256-QzuL1epLvjF62isUdiRueSfPWsJgdgsadMFOuvv32hs="; };
                };
              in
              # Some exact project pins are absent from nixpkgs' Hackage index.
              # Fetch those release archives by content hash, without relaxing bounds.
              builtins.mapAttrs (name: pin:
                if prev.${name}.version == pin.version then prev.${name}
                else pkgs.haskell.lib.dontCheck (final.callCabal2nix name (pkgs.fetchzip {
                  url = "https://hackage-content.haskell.org/package/${name}-${pin.version}.tar.gz";
                  inherit (pin) hash;
                }) { })) pinned
              // builtins.listToAttrs (map (name: {
                inherit name;
                value = pkgs.haskell.lib.dontCheck
                  (final.callCabal2nix name (agentic + "/${name}")
                    (pkgs.lib.optionalAttrs
                      (builtins.elem name [ "agentic-openai" "agentic-anthropic" "agentic-jev" ])
                      { agentic-io = null; }));
              }) [ "agentic" "agentic-aeson" "agentic-openai" "agentic-anthropic" "agentic-jev" ])
              // builtins.mapAttrs (name: path:
                pkgs.haskell.lib.overrideCabal
                  (final.callCabal2nix name (self + "/${path}") { })
                  (_: {
                    # Some packages share source and guide files across directories.
                    src = source;
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
          kyyn-sdk = p.haskell.kyyn-sdk;
          kyyn-guest-build = p.haskell.kyyn-guest-build;
          default = self.packages.${system}.kyyn;
        });
      legacyPackages = forAllSystems (system: (project system).haskell);
      checks = forAllSystems (system:
        let
          p = project system;
          capturedSource = p.pkgs.runCommand "kyyn-captured-plugin-source" { } ''
            mkdir -p "$out/plugins/packages/local-file/source"
            cp -R ${./tools/fixtures/ghc-guest}/. "$out/"
            cp -R ${./tools/fixtures/captured-plugin}/. "$out/plugins/packages/local-file/source/"
          '';
          schemaSource = p.pkgs.runCommand "kyyn-schema-discovery-source" { } ''
            mkdir -p "$out"
            cp -R ${./tools/fixtures/ghc-guest}/. "$out/"
            chmod -R u+w "$out"
            printf '%s\n' '{"selection":"schema"}' > "$out/.kyyn-build.json"
            printf '%s\n' 'module Queries where' 'unfinished =' > "$out/src/Queries.hs"
          '';
          bindingApiSource = p.pkgs.runCommand "kyyn-binding-api-source" { } ''
            mkdir -p "$out"
            cp -R ${./tools/fixtures/ghc-guest}/. "$out/"
            chmod -R u+w "$out"
            printf '%s\n' '{"selection":"modules","modules":["Queries","KyynQueryBindings"]}' > "$out/.kyyn-build.json"
            printf '%s\n' 'module Evolution where' 'unfinished =' > "$out/src/Evolution.hs"
          '';
          apiSource = p.pkgs.runCommand "kyyn-api-discovery-source" { } ''
            mkdir -p "$out/src"
            printf '%s\n' '{"selection":"modules","modules":["Example","Data.Maybe","Kyyn.Optics"]}' > "$out/.kyyn-build.json"
            printf '%s\n' 'unfinished manifest' > "$out/kb.dhall"
            printf '%s\n' 'module Example (answer) where' 'answer :: Integer' 'answer = 42' 'private = True' > "$out/src/Example.hs"
            printf '%s\n' 'module Broken where' 'unfinished =' > "$out/src/Broken.hs"
          '';
        in {
          guest = self.lib.mkGuest { inherit system; src = ./tools/fixtures/ghc-guest; };
          guest-captured = self.lib.mkGuest { inherit system; src = capturedSource; };
          guest-schema = self.lib.mkGuest { inherit system; src = schemaSource; };
          guest-api = self.lib.mkGuest { inherit system; src = apiSource; };
          guest-api-bindings = self.lib.mkGuest { inherit system; src = bindingApiSource; };
        });
      lib.mkGuest = { system, src, dependencies ? (h: [ ]),
        haskellPackages ? self.legacyPackages.${system} }:
        let
          p = project system;
          compiler = haskellPackages.ghcWithPackages (h:
            [ h.kyyn-sdk h.kyyn-types h.aeson h.bytestring h.text ] ++ dependencies h);
        in p.pkgs.stdenv.mkDerivation {
          name = "kyyn-guest";
          inherit src;
          nativeBuildInputs = [ compiler haskellPackages.kyyn-guest-build ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            runHook preBuild
            mkdir -p "$out/bin"
            kyyn-guest-build ${compiler}/bin/ghc . "$out/bin/kyyn-guest"
            runHook postBuild
          '';
        };
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
