{ pkgs }:
pkgs.callPackage ./source-package.nix {
  version = "0.2.12";
  src = pkgs.fetchurl {
    url = "https://github.com/IgneousRed/odin-ui/releases/download/v0.2.12/odin_ui-v0.2.12.zip";
    sha256 = "a37aeb694fd176eae1347b5921ab6d4bdf301c3e4a92c808b0fec76170ad6beb";
  };
}
