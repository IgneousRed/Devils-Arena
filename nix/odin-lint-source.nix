{ fetchFromGitHub }:
let
  owner = "IgneousRed";
  repo = "odin-lint";
  version = "0.7.7";
  rev = "45befd178e5289ebd9df7c3074db44ab5a52839d";
  hash = "sha256-w/dhyucY02afACM5IDepq/mAXPUKeZuNSkDkKxrG0f0=";
in
{
  inherit owner repo version rev hash;
  src = fetchFromGitHub { inherit owner repo rev hash; };
}
