{ pkgs }:
pkgs.callPackage ./source-package.nix {
  version = "0.2.10";
  src = pkgs.fetchurl {
    url = "https://github.com/IgneousRed/odin-ui/releases/download/v0.2.10/odin_ui-v0.2.10.zip";
    sha256 = "3ced914bf2bf9ebf1a669422cdb963c03b2f5bf0087a0f0d91efc189cf1d3483";
  };
}
