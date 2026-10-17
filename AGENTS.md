# bb-nix

Public (github.com/djbclark/bb-nix, MIT, created 2026-10-17): NixOS modules `services.bb` and
`services.bb-host-daemon`, and packages for [BB](https://github.com/get-bb/bb) (`bb-app` on npm).
`README.md` is the user documentation; keep it in step with `module.nix` and `host-daemon.nix`.

1. **Generic only.** No host names, IPs, tailnet names, user names as defaults or secrets in this repo. The
   deployment lives elsewhere (djbclark's private/ops repos); examples here use `example.ts.net`.
2. **No Nix on the Mac, and no builds on any host of ours.** Everything is built and checked in Forgejo CI:
   `nix-build` workflow of https://forgejo.mit.edu/djbclark/bb-build (dispatch with repo
   `https://github.com/djbclark/bb-nix.git`, a ref, and the attrs below). A hash left as `lib.fakeHash` fails with
   `got: sha256-...` in the log.
3. **Packages** come from `bb-build`'s CI: `pkgs/pins.json` holds the tarball URLs and hashes of its `PIN bb-app ...` /
   `PIN codex ...` log lines. `lock/package.json` + `lock/package-lock.json` are copies of `bb-build/bundle/` (the
   generic `bb-app` is built from them); `pkgs/bb-app.nix` asserts that the lock and `pins.json` agree.
4. **Upgrade:** bump in bb-build (its README, "Bumping the version"), then in one commit here: `pkgs/pins.json`,
   `lock/`, and the README's version mentions. Dispatch the attrs
   `packages.x86_64-linux.bb-app-bin packages.x86_64-linux.bb-app packages.x86_64-linux.codex-npm-bin
   checks.x86_64-linux.smoke checks.x86_64-linux.module-eval` and wait for `BUILT` on all.
5. **Every flag and environment variable the modules pass was checked against BB's source** (bb-app 0.46.1,
   `packages/bb-app/src/launcher.ts`, `packages/config/src/env-vars.ts`). Re-check after a bump: BB renames and
   moves settings often (for example `BB_SKIP_ONBOARDING` exists on BB's main branch but not in 0.46.1).
6. BB has **no authentication**. Never add an option that opens the port by default, never use `tailscale funnel`.
