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

  # The server builds the host package a new machine downloads (/install/bb-app.tgz) by copying files out
  # of its own package into a temporary directory under <dataDir>/install-cache. From the Nix store the
  # copied bb-chunks directory keeps mode 0555, so the cleanup `rm -r` of that copy fails with EACCES and
  # every download is an HTTP 500 ("The server lacks permission to prepare or read the host package").
  # Make the copy writable just before that cleanup. --replace-fail stops the build if a new bb-app
  # version changes this line. Argument: the directory that holds node_modules.
  patchHostPackage = ''
    patchHostPackage() {
      substituteInPlace "$1/node_modules/bb-app/server/dist/start-server.js" \
        --replace-fail 'await rm16(temporaryHostPackageRoot, { force: true, recursive: true });' \
        'await (async function bbNixWritable(dir) { await chmod(dir, 493); for (const entry of await readdir(dir, { withFileTypes: true })) { if (entry.isDirectory()) await bbNixWritable(join39(dir, entry.name)); } })(temporaryHostPackageRoot); await rm16(temporaryHostPackageRoot, { force: true, recursive: true });'
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
