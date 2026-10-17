# bb-app built on the host from ../lock/package-lock.json (the same lock Forgejo CI packs for bb-app-bin).
# importNpmLock turns every `resolved` + `integrity` pair of the lock into a fetchurl, so there is no
# dependency hash to maintain. Nothing is compiled: bb-app's native modules ship prebuilds and
# --ignore-scripts keeps npm from running anything.
#
# x86_64-linux is built and tested in CI. aarch64-linux evaluates but is unverified: it needs the
# linux-arm64 prebuilds of node-pty and fs-native-extensions to exist in the pinned versions.
{
  lib,
  stdenv,
  callPackage,
  buildNpmPackage,
  importNpmLock,
  autoPatchelfHook,
  makeWrapper,
}:
let
  common = callPackage ./common.nix { };
  pin = (lib.importJSON ./pins.json).bb-app;
  lockedVersion = (lib.importJSON ../lock/package.json).dependencies.bb-app;
in
assert lib.assertMsg (lockedVersion == pin.version)
  "lock/package.json pins bb-app ${lockedVersion} but pkgs/pins.json says ${pin.version}; bump both from the same bb-build run";
buildNpmPackage {
  pname = "bb-app";
  inherit (pin) version;

  src = ../lock;
  npmDeps = importNpmLock { npmRoot = ../lock; };
  npmConfigHook = importNpmLock.npmConfigHook;
  nodejs = common.nodejs;

  npmFlags = [ "--ignore-scripts" ];
  npmRebuildFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  dontNpmInstall = true;
  dontPatchShebangs = true;

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/bb
    cp -r node_modules package.json package-lock.json $out/lib/bb/
    ${common.pruneNative}
    pruneNative $out/lib/bb
    ${common.wrapBins}
    runHook postInstall
  '';

  meta = {
    description = "BB (bb-app): web UI, server and host daemon for coding agents";
    homepage = "https://github.com/get-bb/bb";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "bb-app";
  };
}
