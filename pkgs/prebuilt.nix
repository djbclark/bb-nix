# Prebuilt x86_64-linux packages, downloaded by hash (see pins.json), so a host that uses them compiles nothing.
{ callPackage }:
{
  bb-app-bin = callPackage ./bb-app-bin.nix { };
  codex-npm-bin = callPackage ./codex-npm-bin.nix { };
}
