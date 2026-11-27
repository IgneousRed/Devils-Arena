{ pkgs }:
pkgs.callPackage ./source-package.nix {
  version = "0.2.11";
  src = pkgs.fetchurl {
    url = "https://github.com/IgneousRed/odin-ui/releases/download/v0.2.11/odin_ui-v0.2.11.zip";
    sha256 = "390eacebdd5e6292209cef94261297d4c39a40aa48a5386ca10c415c8e640830";
  };
}
