{ pkgs }:
let
  mermaid = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@mermaid-js/tiny/-/tiny-12.3.0.tgz";
    hash = "sha256-4tdxpMtwJRD6Cg+z6eQPXsFy/5gZJosfpca9RyOXptI=";
  };
  prism = pkgs.fetchurl {
    url = "https://registry.npmjs.org/prismjs/-/prismjs-1.30.0.tgz";
    hash = "sha256-rBapEGooxTtqYxOZPIFqOgJSX9/v12FPwXA9+RWp/BE=";
  };
in pkgs.runCommand "kyyn-web-vendor" { } ''
  mkdir -p "$out" mermaid prism
  tar xf ${mermaid} -C mermaid
  tar xf ${prism} -C prism
  cp mermaid/package/dist/mermaid.tiny.js "$out/mermaid.js"
  cp mermaid/package/LICENSE "$out/mermaid.LICENSE"
  cat prism/package/components/prism-core.min.js prism/package/components/prism-haskell.min.js > "$out/prism.js"
  cp prism/package/themes/prism.css "$out/prism.css"
  cp prism/package/LICENSE "$out/prism.LICENSE"
''
