# bb-app 0.46.1 for x86_64-linux from the tarball Forgejo CI built (djbclark/bb-build): `npm ci` from the
# committed lock, native modules smoke-tested, prebuilds of other platforms pruned. A host that uses this
# compiles nothing and downloads one 40 MB file whose hash is pinned in pins.json.
#
# The tarball has no top-level directory: node_modules/, package.json and package-lock.json sit at its root.
{
  lib,
  stdenv,
  callPackage,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
}:
let
  common = callPackage ./common.nix { };
  pin = (lib.importJSON ./pins.json).bb-app;
in
stdenv.mkDerivation {
  pname = "bb-app-bin";
  inherit (pin) version;

  src = fetchurl { inherit (pin) url hash; };
  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  # libstdc++ and libgcc_s for the .node files; libc comes with stdenv.
  buildInputs = [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchShebangs = true;

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
    description = "BB (bb-app): web UI, server and host daemon for coding agents, prebuilt by CI";
    homepage = "https://github.com/get-bb/bb";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "bb-app";
  };
}
