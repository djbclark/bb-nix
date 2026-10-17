# The OpenAI Codex CLI (@openai/codex on npm) for x86_64-linux, packed by Forgejo CI (djbclark/bb-build)
# and pinned by hash in pins.json. BB needs Codex 0.136.0 or newer to drive it; this is 0.154.0.
# The npm tree holds a node launcher and its static platform binary, so nothing needs patching.
# `codex` is a wrapper around Node, so it works for an agent user whose login PATH has no `node`.
{
  lib,
  fetchurl,
  runCommandLocal,
  makeWrapper,
  nodejs_24,
}:
let
  pin = (lib.importJSON ./pins.json).codex;
  tarball = fetchurl { inherit (pin) url hash; };
in
runCommandLocal "codex-npm-bin-${pin.version}"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta = {
      description = "OpenAI Codex CLI, as published on npm";
      homepage = "https://github.com/openai/codex";
      license = lib.licenses.asl20;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      platforms = [ "x86_64-linux" ];
      mainProgram = "codex";
    };
  }
  ''
    mkdir -p $out/lib $out/bin
    tar -xzf ${tarball} -C $out/lib
    test -f $out/lib/node_modules/@openai/codex/bin/codex.js
    makeWrapper ${lib.getExe nodejs_24} $out/bin/codex \
      --add-flags $out/lib/node_modules/@openai/codex/bin/codex.js
  ''
