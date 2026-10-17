# bb-nix

NixOS modules and Nix packages for [BB](https://github.com/get-bb/bb) (the `bb-app` npm package): a web UI and
server for coding agents (Claude Code, Codex, and any ACP agent) that runs their threads on one or many machines.
An unofficial packaging, MIT like BB. Pinned to **BB 0.46.1** and Codex 0.154.0; both are updated here by hand.

```
services.bb              one unit: BB server + web UI + a host daemon on the same machine
services.bb-host-daemon  a host daemon on another machine, joined to that server
packages: bb-app (built from the npm lock), bb-app-bin (CI tarball, x86_64-linux), codex-npm-bin
```

## Who it is for

1. Anyone who wants BB on a NixOS box (a VPS, a home server, a microVM) instead of the desktop app, reachable from a
   browser or phone over a tailnet, with their laptop and other machines added as places the agents can run.
2. Anyone who needs the pieces: a `bb-app` that runs from the read-only Nix store, a Codex CLI that works for a user
   without Node on their PATH, and a worked example of a userspace-Tailscale host (a libkrun microVM) that joins a
   remote server.

Light on purpose: this is a systemd unit and a user, not a sandbox (see [Hardening](#hardening-is-light-on-purpose)).
It is part of [djbclark/mit](https://forgejo.mit.edu/djbclark/mit), the index of the author's MIT / SIPB projects, and was
written for an MIT SIPB microVM ([`get`](https://forgejo.mit.edu/djbclark/get)) plus a small VPS, but nothing in it is
specific to either.

## BB's API has no login

**Read this before you open a port.** BB has no authentication. Its own README says the public API is
unauthenticated and permits command execution and file reads. Anyone who can reach the port can start an agent as the
service user, read that user's files (including `~/.ssh`, `~/.claude`, `~/.codex`) and see every thread.

1. The module therefore binds the server to `127.0.0.1` only (`bindHost`), and `openFirewall` is off.
2. The intended exposure is **your tailnet**, with `tailscale serve` (`tailscaleServe.enable`): everyone who can reach
   the node over Tailscale can use BB, so the tailnet ACL is the access control. If your ACL is allow-all, every device
   and every shared-in user on the tailnet gets a shell as the BB user.
3. **Never use `tailscale funnel`** (the module only ever runs `serve`) and never publish the port on the internet.
   A reverse proxy in front must authenticate the request itself (client certificates, a proxy login).
4. Several things BB hands out are only as safe as that boundary: the one-time machine enrolment credentials, the
   enrol-key route (loopback-only by socket address, but behind `tailscale serve` every request arrives from
   loopback), and the `x-bb-gate-*` headers of BB's own relay, which a direct client can forge.

## Single host: quick start

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.bb-nix.url = "github:djbclark/bb-nix";
  inputs.bb-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, bb-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        bb-nix.nixosModules.default
        ./configuration.nix
        ({ pkgs, ... }: {
          services.tailscale.enable = true;     # logged in, with HTTPS certificates enabled for the tailnet
          services.bb = {
            enable = true;
            package = bb-nix.packages.x86_64-linux.bb-app-bin;   # the CI tarball: nothing is built or fetched but one file
            appUrl = "https://myhost.example.ts.net";            # required: BB rejects any other Host name
            tailscaleServe.enable = true;                        # https://myhost.example.ts.net, tailnet only
            extraPackages = [
              bb-nix.packages.x86_64-linux.codex-npm-bin         # Codex CLI (BB needs >= 0.136.0)
              pkgs.gh pkgs.ripgrep
            ];
            claudeCode.nativeInstaller = true;                   # nix-ld + ~/.local/bin for Anthropic's installer
            claudeCode.executable = "/var/lib/bb/.local/bin/claude";
            memoryHigh = "2560M"; memoryMax = "3G";              # optional: cap the server and its agents together
          };
        })
      ];
    };
  };
}
```

After the switch:

```bash
curl -fsS http://127.0.0.1:38886/health       # {"ok":true,"launchId":"..."}
# a shorthand for the BB CLI as the service user (it needs the data dir and the server address, and a
# working directory the bb user can enter: from /root or your home it dies with "spawn .../bin/node EACCES"):
bbcli() { (cd /tmp && sudo -u bb -H env BB_DATA_DIR=/var/lib/bb BB_SERVER_URL=http://127.0.0.1:38886 bb "$@"); }
bbcli --version
```

Open the `appUrl` in a browser on a device on the tailnet. The server and its local host daemon start together and the
daemon joins by itself; no account is needed and no machine enrolment for the first host.

### Log the agents in, once, as the service user

1. **Claude Code**: `sudo -u bb -H bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'` (Anthropic's installer,
   into `~/.local/bin`), then `sudo -u bb -H ~bb/.local/bin/claude` and `/login`. Set `claudeCode.executable` to the
   path. The module turns on `programs.nix-ld` for that generic glibc binary when `claudeCode.nativeInstaller` is set.
   To use a token instead of a login, put `CLAUDE_CODE_OAUTH_TOKEN=...` in a file and point `environmentFile` at it.
2. **Codex**: `sudo -u bb -H codex login --device-auth` (with `codex-npm-bin` in `extraPackages`).
3. Restart (`systemctl restart bb`) if BB was already running: it reads each CLI's presence when it starts a thread.

## Adding another machine

Every other machine runs a host daemon that dials **out** to the server (`wss://<server>/internal/ws`). The server
needs no route to the machine. Use BB's "Manual" provider ("Use your own domain or network address"), not `bb connect`.

1. On the server, give machines an address to dial: `externalUrl` sets `BB_EXTERNAL_URL`, which is the default
   `machineServerUrl` (Settings, Machines, "Server URL reachable by machines"). With `tailscaleServe.ports = [ 443
   38443 ]` a second HTTPS port serves the same backend, which is handy for daemons.
2. On the new NixOS machine, enable the daemon module. The unit stays inactive until the machine is enrolled:

   ```nix
   services.bb-host-daemon = {
     enable = true;
     package = bb-nix.packages.x86_64-linux.bb-app-bin;     # the same version as the server
     serverUrl = "https://myhost.example.ts.net:38443";     # exactly the URL used at enrolment
     # user = "alice"; createUser = false; dataDir = "/persist/bb";   # run agents as an existing user
     extraPackages = [ bb-nix.packages.x86_64-linux.codex-npm-bin pkgs.git ];
   };
   ```

3. **Enrol, once.** In the BB UI: Settings, Machines, add a machine, **Manual**. BB shows
   `curl -sSL --fail-with-body -H 'X-BB-Enrollment: <credential>' '<server>/install.sh' | sh`. The credential is a
   secret that lasts 15 minutes. Do not run BB's installer on NixOS (it installs from npm into the home directory and
   writes a service unit); take only the enrolment header from the script it serves, whose first line is
   `export BB_ENROLLMENT='{...}'`:

   ```bash
   read -rsp 'enrolment credential: ' CRED; echo
   printf 'header = "X-BB-Enrollment: %s"\n' "$CRED" |
     curl --config - -sSL --fail-with-body 'https://myhost.example.ts.net:38443/install.sh' | head -1 |
     sudo -u bb -H sh -c 'read -r line
       case "$line" in "export BB_ENROLLMENT="*) eval "$line" ;; *) echo "unexpected script" >&2; exit 1 ;; esac
       BB_DATA_DIR=/var/lib/bb-host bb machine enroll --bootstrap-env BB_ENROLLMENT'
   unset CRED
   sudo systemctl start bb-host-daemon
   ```

   The credential goes through a pipe and the environment only (no file, nothing in `ps`).
   Use the module's `user` and `dataDir` (the defaults above are `bb` and `/var/lib/bb-host`). `bb machine enroll`
   writes `config.json`, `host-id` and `auth.json` into the data dir, and refuses a different server or machine id
   later. The daemon's unit has `ConditionPathExists = <dataDir>/auth.json`, so after the first enrolment it starts
   at every boot by itself.
4. The machine shows up online in Settings, Machines. Log the agents in on it as its user, as above.

An existing user (`createUser = false`) keeps its home and groups: the module creates, chowns and chmods nothing for
it, and sets no `StateDirectory`. Put the agent tools in that user's own profile, because BB reads each thread's PATH
from the user's login shell.

### A userspace-Tailscale host (a libkrun microVM)

A Hyades microVM (or any container) has no TUN device, so Tailscale runs in userspace and the host has no tailnet
interface: nothing but `tailscaled` can open a connection to the tailnet. The BB daemon's WebSocket client ignores
proxy settings, so a small forwarder goes between them:

```
daemon --> 127.0.0.1:38443 (socat, bb-tailnet-forward) --HTTP CONNECT--> tailscaled :1055 --> tailnet --> server :38443
```

```nix
services.tailscale = {
  enable = true;
  interfaceName = "userspace-networking";
  extraDaemonFlags = [ "--outbound-http-proxy-listen=localhost:1055" ];
};
services.bb-host-daemon = {
  enable = true;
  serverUrl = "https://myhost.example.ts.net:38443";   # the real name: TLS and SNI match tailscale serve
  hostsEntry = true;                                   # /etc/hosts: that name -> 127.0.0.1 (the forwarder)
  forwarder = {
    enable = true;
    listenPort = 38443;
    proxy = "127.0.0.1:1055";
    target = "100.64.0.1:38443";                       # the server as the proxy dials it (a tailnet IP is the safe choice)
  };
  ldPreload = "/run/current-system/sw/lib/portshim.so";  # libkrun only, see below
};
```

TLS stays end to end. Under libkrun's TSI networking, sockets behave differently (a listener on port 0 is unreachable, a
blocked `recv` holds the socket lock); the
[loopback-port-shim](https://forgejo.mit.edu/djbclark/loopback-port-shim) `LD_PRELOAD` library works around them. Build it
with `gcc -shared -fPIC -O2 -pthread -o portshim.so loopback-port-shim.c -ldl` and point `ldPreload` at the result. The
daemon listens on a fixed port (`port`), so the port-0 bug does not hit the daemon itself; `ldPreload` sets the
variable on the daemon process only (whether the processes it starts for the agents inherit it is untested; for those,
`/etc/ld.so.preload` is the wider tool). See that repository for what was measured.

## Settings that are not in Nix

These live in BB's database (`<dataDir>/bb.db`), not in a file or an environment variable, so the module cannot set
them. Run them once as the service user (`bbcli`, above) against the running server:

| What | Command | Why |
| --- | --- | --- |
| Use the "Manual" provider for new machines | `bbcli settings general defaultMachineAccess direct` | The default provider is `bb connect` while that plugin runs |
| Turn off the cloud relay and account plugins | `bbcli plugin disable connect`, `... bb-account`, `... bb-ai` | They are inert unless you sign in; disable them if you want no path to getbb.app |
| Add an ACP agent BB does not ship | `bbcli plugin config provider-acp set customAgents '[{"id":"amp","displayName":"Amp","command":"amp","args":["acp"]}]'` | Providers become `acp-<id>`; commands run as the BB user on the thread's host |
| Machine address (if you do not set `externalUrl`) | `bbcli settings general machineServerUrl https://...` | Overrides `BB_EXTERNAL_URL` |

Do not also set BB's own `bb-app env set` / `config set` keys that the module sets: BB's `env.json` and `config.json`
override the unit's environment (the order is environment, then command-line flags, then `config.json`, then `env.json`).

## Updating

BB's version is the version of the flake, not of an in-app updater: the unit runs `bb-app --no-in-app-updates`, because
the program is in the read-only store. To update, bump `pkgs/pins.json` and `lock/` here, from a new run of
[djbclark/bb-build](https://forgejo.mit.edu/djbclark/bb-build) (Forgejo CI that packs `bb-app` and the Codex npm package into
hash-pinned tarballs). Then `nix flake update bb-nix` in your system flake and switch.

1. **Back up the data dir first**: BB migrates its database when it starts, so going back needs the backup.
2. Update the server and every joined daemon together: daemons and servers speak a versioned protocol.
3. `bb-app-bin` and `bb-app` are the same BB version (the generic package asserts that the lock and the pin agree).

## Options

### `services.bb`

| Option | Default | |
| --- | --- | --- |
| `enable` | `false` | Server and the co-located host daemon |
| `package` | `bb-app` from the lock | `bb-app-bin` (x86_64-linux) is the CI tarball |
| `nodejs` | `pkgs.nodejs_24` | On PATH; `npm` is needed (the server packs the host package with `npm pack`) |
| `user`, `group` | `bb`, `bb` | System user the agents run as; the module creates both, with a bash login shell |
| `dataDir` | `/var/lib/bb` | `--data-dir` / `BB_DATA_DIR`, and the user's `$HOME`. Back it up |
| `port` | `38886` | `--server-port` |
| `hostDaemonPort` | `38887` | `--host-daemon-port` |
| `bindHost` | `127.0.0.1` | `--server-bind-host`; `0.0.0.0` exposes an unauthenticated API |
| `appUrl` | `null` | `BB_APP_URL`: the URL people open. Required behind a DNS name |
| `externalUrl` | `null` | `BB_EXTERNAL_URL`: default machine server URL for enrolment |
| `telemetry` | `false` | `BB_TELEMETRY` (BB's own default is on) |
| `claudeCode.executable` | `null` | `BB_CLAUDE_CODE_EXECUTABLE` |
| `claudeCode.nativeInstaller` | `false` | `programs.nix-ld` and `environment.localBinInPath` |
| `extraPackages` | `[ ]` | Agent tools: the user's profile and the unit's PATH |
| `environment` | `{ }` | More unit environment; never secrets |
| `environmentFile` | `null` | `EnvironmentFile` for secrets such as `CLAUDE_CODE_OAUTH_TOKEN` |
| `memoryHigh`, `memoryMax` | `null` | systemd limits for the server and every agent |
| `tailscaleServe.enable` | `false` | One `tailscale serve` unit per port; never funnel |
| `tailscaleServe.ports` | `[ 443 ]` | HTTPS ports for this backend |
| `openFirewall` | `false` | Needs `bindHost = "0.0.0.0"` |

### `services.bb-host-daemon`

| Option | Default | |
| --- | --- | --- |
| `enable` | `false` | |
| `package`, `nodejs` | as above | Same version as the server |
| `serverUrl` | (required) | `--server-url`; must equal the enrolment URL |
| `user`, `createUser` | `bb`, `true` | The user agents run as; `false` leaves that user untouched |
| `dataDir` | `/var/lib/bb-host` | `--data-dir`: identity, logs, worktrees. With a created user it is also the home |
| `port` | `38888` | `--host-daemon-port` (loopback) |
| `ldPreload` | `null` | For example the loopback-port-shim under libkrun |
| `extraPackages` | `[ ]` | Agent tools |
| `forwarder.enable` | `false` | The socat loopback forwarder unit |
| `forwarder.listenPort`, `.proxy`, `.target` | `38443`, `127.0.0.1:1055`, `null` | Listen port, CONNECT proxy, server `host:port` |
| `hostsEntry` | `false` | `/etc/hosts`: the server's host name to 127.0.0.1 |

Do not enable both modules on one machine: `services.bb` already runs a daemon (an assertion enforces it).

## Packages

| Package | |
| --- | --- |
| `bb-app` (`default`) | `buildNpmPackage` from `lock/` with `importNpmLock` (no dependency hash to maintain); x86_64-linux is built in CI, aarch64-linux evaluates but is unverified |
| `bb-app-bin` | The tarball CI built: x86_64-linux, pinned by hash, 40 MB, `autoPatchelfHook` over the four prebuilt native modules |
| `codex-npm-bin` | `@openai/codex` 0.154.0 from npm, wrapped in Node, pinned by hash |

`overlays.default` adds all three to nixpkgs. Nothing is compiled: BB's native modules (better-sqlite3, node-pty,
@parcel/watcher, fs-native-extensions) ship prebuilt N-API binaries, which are linked against glibc and libstdc++, so
the packages patch them for the store and delete the prebuilds of other platforms.

## What the modules do to the host

1. `services.bb` creates the user and group, a unit `bb.service` (`bb-app --no-in-app-updates --data-dir ... `) that
   restarts on failure, `tailscale-serve` oneshot units per port, and adds the `bb` CLI to the system PATH.
2. BB writes only under its data dir and the user's home (`~/.claude`, `~/.codex`, `~/.local/bin`); worktrees are under
   the data dir. It makes outbound HTTPS calls to the npm registry (version check), `getbb.app` (plugin marketplace,
   refreshed periodically) and, unless `telemetry = false`, PostHog.
3. The user's login PATH is where BB finds `claude`, `codex` and your tools, so `extraPackages` go into the user's
   profile, not only the unit's PATH.

### Hardening is light on purpose

The unit has no `ProtectSystem`, `PrivateTmp`, `NoNewPrivileges` or capability bounding. The agents are the product:
they need a normal home, git, ssh, a writable `/tmp` and whatever tools you give them, and they run arbitrary commands.
The boundary is the dedicated unprivileged user and the tailnet. If you want more (a container, a VM, `ProtectHome`
for other users' homes), add it with `systemd.services.bb.serviceConfig`.

## Checks

`nix flake check` runs `checks.x86_64-linux.smoke`, `module-eval` and, with KVM, `vm`:

1. `smoke` (and `smoke-generic`, for the package built from the lock) starts the packaged `bb-app` for real (a throwaway `HOME` and data dir), waits for `/health`, runs
   `bb --version`, asks the CLI for the co-located machine, and stops it.
2. `module-eval` evaluates sample systems that use both modules down to the system derivation, so a typo in an option
   fails CI. It does not build them.
3. `vm` is a NixOS test that boots `services.bb` under systemd. It needs `/dev/kvm`.

The author builds everything in Forgejo CI on a runner without KVM and without Nix on his laptop; CI builds
every attribute except `vm`.

## License

MIT, like BB. BB is the work of its authors ([get-bb/bb](https://github.com/get-bb/bb)); this repository only packages
it. Issues and pull requests are welcome.
