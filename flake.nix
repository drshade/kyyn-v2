{
  description = "Kyyn host and contributor toolchain";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.agentic = {
    url = "github:drshade/haskell-agentic/46624d9ce48c27a01efcd2873a5bd65af6d41711";
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
              ./host ./guest ./shared ./plugins ./docs/guide.md
            ];
          };
          # cabal.project owns the local package inventory.
          packageBlock = builtins.head (builtins.match
            "packages:([^\n]*(\n[ \t]+[^\n]*)*)\n.*" (builtins.readFile ./cabal.project));
          packagePaths = builtins.filter (x: builtins.isString x && x != "")
            (builtins.split "[[:space:]]+" packageBlock);
          localPackages = builtins.listToAttrs (map (path:
            let
              manifests = builtins.filter (name: pkgs.lib.hasSuffix ".cabal" name)
                (builtins.attrNames (builtins.readDir (self + "/${path}")));
            in assert builtins.length manifests == 1; {
              name = pkgs.lib.removeSuffix ".cabal" (builtins.head manifests);
              value = path;
            }) packagePaths);
          # Initialization copies a standard, already locked KB flake. Published
          # builds pin this repository revision; dirty contributor builds retain
          # their immutable local source so installed tests need no remote commit.
          guestInput = if self ? rev then {
            type = "github"; owner = "drshade"; repo = "kyyn-v2"; rev = self.rev;
          } else { type = "path"; path = toString self.outPath; };
          guestUrl = if self ? rev then "github:drshade/kyyn-v2/${self.rev}" else "path:${self.outPath}";
          repositoryLock = builtins.fromJSON (builtins.readFile ./flake.lock);
          templateLock = repositoryLock // {
            nodes = repositoryLock.nodes // {
              kyyn = { inputs = repositoryLock.nodes.root.inputs;
                original = guestInput;
                locked = guestInput // { inherit (self) narHash; lastModified = self.lastModified or 0; };
              };
              root.inputs.kyyn = "kyyn";
            };
          };
          template = pkgs.runCommand "kyyn-kb-template" { } ''
            mkdir -p "$out"
            cp -R ${./templates/kb}/. "$out/"
            chmod -R u+w "$out"
            cp ${pkgs.writeText "flake.nix" ''
              {
                description = "Kyyn knowledge base";
                inputs.kyyn.url = "${guestUrl}";
                outputs = { self, kyyn }: {
                  packages = builtins.listToAttrs (map (system: {
                    name = system;
                    value.kyyn-guest = kyyn.lib.mkGuest { inherit system; src = self; };
                  }) [ ${builtins.concatStringsSep " " (map builtins.toJSON systems)} ]);
                };
              }
            ''} "$out/flake.nix"
            cp ${pkgs.writeText "flake.lock" (builtins.toJSON templateLock)} "$out/flake.lock"
          '';
          haskell = pkgs.haskell.packages.ghc9141.override {
            overrides = final: prev:
              {
                # Upstream #171: GHC 9.14 changes Core, breaking an inspection test.
                # Remove dontCheck when generic-lens updates that test; Kyyn tests the optics.
                generic-lens = pkgs.haskell.lib.dontCheck final.generic-lens_2_3_0_0;
                generic-lens-core = final.generic-lens-core_2_3_0_0;
                # Upstream dhall-haskell #2704; remove this patch at the next release.
                dhall = pkgs.haskell.lib.overrideCabal prev.dhall (old: {
                  patches = (old.patches or []) ++ [ (pkgs.fetchpatch {
                    url = "https://github.com/dhall-lang/dhall-haskell/commit/f741afffafc3131cc5a8dd896749c35ed49bfd0a.patch";
                    stripLen = 1;
                    hash = "sha256-Q/L6Q2XTnoYpIT8w5bqH7RGoLoxUh5QFAOTW9Wt9Hzc=";
                  }) ];
                });
                # Remove bound patches when upstream Hackage revisions admit GHC 9.14.
                cborg-json = pkgs.haskell.lib.overrideCabal prev.cborg-json (old: {
                  postPatch = (old.postPatch or "") + ''
                    substituteInPlace cborg-json.cabal --replace-fail '< 4.22' '< 4.23'
                  '';
                });
                repline = pkgs.haskell.lib.overrideCabal prev.repline (old: {
                  postPatch = (old.postPatch or "") + ''
                    substituteInPlace repline.cabal --replace-fail 'containers  >=0.5  && <0.8' 'containers  >=0.5  && <0.9'
                  '';
                });
              }
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
                  } // pkgs.lib.optionalAttrs (name == "kyyn") {
                    configureFlags = [ ''--ghc-option=-DKYYN_TEMPLATE_DIRECTORY="${template}"'' ];
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
          toolSource = p.pkgs.runCommand "kyyn-tool-source" { } ''
            mkdir -p "$out"
            cp -R ${capturedSource}/. "$out/"
            chmod -R u+w "$out"
            cp -R ${./tools/fixtures/tool-guest}/. "$out/"
          '';
          modelSource = p.pkgs.runCommand "kyyn-model-source" { } ''
            mkdir -p "$out"
            cp -R ${./tools/fixtures/ghc-guest}/. "$out/"
            chmod -R u+w "$out"
            cp -R ${./tools/fixtures/model-guest}/. "$out/"
          '';
          recipeSource = p.pkgs.runCommand "kyyn-recipe-source" { } ''
            mkdir -p "$out"
            cp -R ${toolSource}/. "$out/"
            chmod -R u+w "$out"
            cp -R ${./tools/fixtures/recipe-guest}/. "$out/"
          '';
          recipeEvolutionSource = p.pkgs.runCommand "kyyn-recipe-evolution-source" { } ''
            mkdir -p "$out"
            cp -R ${./tools/fixtures/target-evolution-guest}/. "$out/"
            chmod -R u+w "$out"
            cp -R ${./tools/fixtures/recipe-evolution-guest}/. "$out/"
            printf '%s\n' '{"selection":"evolution","details":{"recipes":[{"kind":"flow","name":"Flows.review"}],"recipe":{"tag":"Some","value":{"kind":"flow","name":"Flows.review"}},"modules":{"tag":"None"}}}' > "$out/.kyyn-build.json"
          '';
          frozenApiSource = p.pkgs.runCommand "kyyn-frozen-api-source" { } ''
            mkdir -p "$out"
            cp -R ${recipeEvolutionSource}/. "$out/"
            chmod -R u+w "$out"
            printf '%s\n' '{"selection":"evolution","details":{"recipes":[{"kind":"flow","name":"Flows.review"}],"recipe":{"tag":"Some","value":{"kind":"flow","name":"Flows.review"}},"modules":{"tag":"Some","value":["KyynFrozenProposal"]}}}' > "$out/.kyyn-build.json"
            printf '%s\n' 'deliberately invalid proposal data; discovery must not decode it' > "$out/.kyyn-change/proposal.dhall"
            printf '%s\n' 'module Evolution where' 'import KyynFrozenProposal' 'unfinished =' > "$out/.kyyn-change/Evolution.hs"
          '';
          rootApiSource = p.pkgs.runCommand "kyyn-root-api-source" { } ''
            mkdir -p "$out"
            cp -R ${toolSource}/. "$out/"
            chmod -R u+w "$out"
            printf '%s\n' '{"selection":"rootApi","selected":{"tag":"None"}}' > "$out/.kyyn-build.json"
            printf '%s\n' 'module Unfinished where' 'unfinished =' > "$out/src/Unfinished.hs"
          '';
          outputSource = p.pkgs.runCommand "kyyn-output-source" { } ''
            mkdir -p "$out"
            cp -R ${toolSource}/. "$out/"
            chmod -R u+w "$out"
            cp -R ${./tools/fixtures/output-guest}/. "$out/"
          '';
          toolApiSource = p.pkgs.runCommand "kyyn-tool-api-source" { } ''
            mkdir -p "$out"
            cp -R ${toolSource}/. "$out/"
            chmod -R u+w "$out"
            printf '%s\n' '{"selection":"modules","modules":["Tools","Kyyn.Connectors","Kyyn.Agentic","Kyyn.Plugins.P_local_file.Files","Kyyn.Plugins.P_local_file.Files.Evidence"]}' > "$out/.kyyn-build.json"
            printf '%s\n' 'unfinished manifest' > "$out/kb.dhall"
            printf '%s\n' 'module Main where' 'unfinished =' > "$out/src/Main.hs"
          '';
          pluginsOnlySource = p.pkgs.runCommand "kyyn-plugins-only-source" { } ''
            mkdir -p "$out/plugins/packages/local-file/source" "$out/src"
            cp -R ${./tools/fixtures/captured-plugin}/. "$out/plugins/packages/local-file/source/"
            printf '%s\n' '{"selection":"plugins"}' > "$out/.kyyn-build.json"
            printf '%s\n' 'unfinished manifest' > "$out/kb.dhall"
            printf '%s\n' 'module Main where' 'unfinished =' > "$out/src/Main.hs"
          '';
          firstPartySource = p.pkgs.runCommand "kyyn-first-party-source" { } ''
            mkdir -p "$out/plugins/packages"
            ${builtins.concatStringsSep "\n" (map (name: ''
              mkdir -p "$out/plugins/packages/${name}/source"
              cp -R ${./plugins + "/${name}"}/. "$out/plugins/packages/${name}/source/"
            '') [ "microsoft-graph" "salesforce" "github" ])}
            printf '%s\n' '{"selection":"plugins"}' > "$out/.kyyn-build.json"
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
            printf '%s\n' 'module Example (answer) where' 'import Data.Maybe (fromMaybe)' 'answer :: Integer' 'answer = fromMaybe 42 Nothing' 'private = True' > "$out/src/Example.hs"
            printf '%s\n' 'module Broken where' 'unfinished =' > "$out/src/Broken.hs"
          '';
        in {
          guest = self.lib.mkGuest { inherit system; src = ./tools/fixtures/ghc-guest; };
          guest-captured = self.lib.mkGuest { inherit system; src = capturedSource; };
          guest-frozen-api = self.lib.mkGuest { inherit system; src = frozenApiSource; };
          guest-model = self.lib.mkGuest { inherit system; src = modelSource; };
          guest-tool = self.lib.mkGuest { inherit system; src = toolSource; };
          guest-root-api = self.lib.mkGuest { inherit system; src = rootApiSource; };
          guest-recipe-evolution = self.lib.mkGuest { inherit system; src = recipeEvolutionSource; };
          guest-target-evolution = self.lib.mkGuest { inherit system; src = ./tools/fixtures/target-evolution-guest; };
          guest-recipe = self.lib.mkGuest { inherit system; src = recipeSource; };
          guest-output = self.lib.mkGuest { inherit system; src = outputSource; };
          guest-api-tools = self.lib.mkGuest { inherit system; src = toolApiSource; };
          guest-plugins = self.lib.mkGuest { inherit system; src = pluginsOnlySource; };
          guest-first-party = self.lib.mkGuest { inherit system; src = firstPartySource; };
          guest-schema = self.lib.mkGuest { inherit system; src = schemaSource; };
          guest-api = self.lib.mkGuest { inherit system; src = apiSource; };
          guest-api-bindings = self.lib.mkGuest { inherit system; src = bindingApiSource; };
        });
      lib.mkGuest = { system, src, dependencies ? (h: [ ]),
        haskellPackages ? self.legacyPackages.${system} }:
        let
          p = project system;
          compiler = haskellPackages.ghcWithPackages (h:
            [ h.kyyn-sdk h.kyyn-types h.kyyn-guest-build
              h.aeson h.bytestring h.text h.containers h.time
              h.cryptohash-sha256 h.lens h.generic-lens ] ++ dependencies h);
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
