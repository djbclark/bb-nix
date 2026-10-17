# Shell fragments shared by bb-app.nix (built from the lock) and bb-app-bin.nix (the CI tarball), so the
# two packages lay out $out the same way. Called with callPackage.
{
  lib,
  stdenv,
  nodejs_24,
}:
let
  # The prebuilt native modules of the other CPU: kept out so autoPatchelf has nothing foreign to patch.
  otherArch = if stdenv.hostPlatform.isAarch64 then "x64" else "arm";
in
{
  nodejs = nodejs_24;

  # Delete the native prebuilds this platform cannot load: other OS, musl, the other CPU. bb-app's four native
  # modules (better-sqlite3, node-pty, @parcel/watcher, fs-native-extensions) ship all of them side by side.
  # Argument: the directory that holds node_modules.
  pruneNative = ''
    pruneNative() {
      local root="$1"
      find "$root/node_modules" -type d -name prebuilds -prune -print0 | while IFS= read -r -d "" d; do
        find "$d" -mindepth 1 -maxdepth 1 \( \
          -name '*darwin*' -o -name '*win32*' -o -name '*musl*' -o -name '*android*' \
          -o -name '*freebsd*' -o -name 'ios-*' -o -name '*${otherArch}*' \) -exec rm -rf {} +
      done
      for d in "$root"/node_modules/@parcel/watcher-*; do
        [ -e "$d" ] || continue
        case "$d" in
          *darwin*|*win32*|*android*|*freebsd*|*musl*|*linux-${otherArch}*) rm -rf "$d" ;;
        esac
      done
    }
  '';

  # One wrapper per bin of the bb-app package (its package.json "bin" map: bb-app, bb, bb-server,
  # bb-host-daemon). Node runs the dist script directly; npm (for `npm pack` of the host package, which
  # the server needs on PATH) comes from the same Node.
  wrapBins = ''
    mkdir -p $out/bin
    for b in bb-app bb bb-server bb-host-daemon; do
      test -f $out/lib/bb/node_modules/bb-app/dist/$b.js
      makeWrapper ${lib.getExe nodejs_24} $out/bin/$b \
        --add-flags $out/lib/bb/node_modules/bb-app/dist/$b.js \
        --prefix PATH : ${lib.makeBinPath [ nodejs_24 ]}
    done
  '';
}
