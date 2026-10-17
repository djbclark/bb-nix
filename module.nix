# services.bb: BB (github.com/get-bb/bb) on NixOS. One systemd unit runs `bb-app`, which supervises the
# BB server (web UI and API) and a host daemon on the same machine, as an unprivileged user. Other
# machines join it with services.bb-host-daemon (host-daemon.nix) or BB's own installer.
#
#   inputs.bb-nix.url = "github:djbclark/bb-nix";
#   imports = [ inputs.bb-nix.nixosModules.default ];
#   services.bb = { enable = true; appUrl = "https://bb.example.ts.net"; tailscaleServe.enable = true; };
#
# BB HAS NO LOGIN. Whoever can reach its port can run commands as the service user and read its files.
# The module binds it to loopback and offers no way to open it to the world; put it behind something
# that decides who may connect (a tailnet is the intended one). Usage and the reasons behind each
# choice: README.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.bb;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    types
    ;

  # A data dir directly under /var/lib is created and owned by systemd's StateDirectory; anywhere else
  # the user's home (the same path) is made by the user database and its parent must exist.
  underVarLib = lib.hasPrefix "/var/lib/" cfg.dataDir;

  tailscale = config.services.tailscale.package;
  serveUnitName = port: "bb-tailscale-serve-${toString port}";
in
{
  options.services.bb = {
    enable = mkEnableOption "BB, a web UI and server for coding agents (bb-app: server plus a host daemon on this machine)";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./pkgs/bb-app.nix { };
      defaultText = lib.literalMD "`bb-app` built from the committed npm lock";
      description = ''
        Package providing `bin/bb-app`, `bin/bb`, `bin/bb-server` and `bin/bb-host-daemon`. The flake's
        `bb-app-bin` (x86_64-linux) is the CI-built tarball, for hosts that should compile and fetch
        nothing else.
      '';
    };

    nodejs = mkOption {
      type = types.package;
      default = pkgs.nodejs_24;
      defaultText = lib.literalExpression "pkgs.nodejs_24";
      description = ''
        Node.js on the service's PATH. The server runs `npm pack` from PATH to build the package that
        other machines install, so it must provide `npm`. BB supports Node 22.19+, 24 and 26.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "bb";
      description = ''
        System user the server, its host daemon and every agent run as (the module creates it, with a
        login shell: BB reads each thread's PATH from the user's login shell). The agents get this user's
        files, SSH keys and git credentials, so keep it dedicated.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "bb";
      description = "Primary group of the service user.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/bb";
      description = ''
        BB's state (`--data-dir` and `BB_DATA_DIR`: database, logs, worktrees, the key that encrypts stored
        environment variables) and also the service user's `$HOME`, where the agents keep `~/.claude`
        and `~/.codex`. Back it up.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 38886;
      description = "`--server-port`: the HTTP port of the server and web UI.";
    };

    hostDaemonPort = mkOption {
      type = types.port;
      default = 38887;
      description = "`--host-daemon-port`: the loopback API port of the host daemon on this machine.";
    };

    bindHost = mkOption {
      type = types.enum [
        "127.0.0.1"
        "0.0.0.0"
      ];
      default = "127.0.0.1";
      description = ''
        `--server-bind-host`. Leave it on loopback and publish through `tailscaleServe` or a reverse
        proxy that authenticates. `0.0.0.0` exposes an API that has no login (see the README).
      '';
    };

    appUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://bb.example.ts.net";
      description = ''
        `BB_APP_URL`: the URL people open BB at. BB rejects any request whose Host is not `localhost`, an
        IP address or this URL's host, and any browser Origin that is not this origin, so it is required
        as soon as you reach BB by a DNS name (including through `tailscale serve`).
      '';
    };

    externalUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://bb.example.ts.net:38443";
      description = ''
        `BB_EXTERNAL_URL`: the address other machines use to reach this server. It is the default
        `machineServerUrl` (Settings, Machines), which the "Manual" enrolment command embeds.
      '';
    };

    telemetry = mkOption {
      type = types.bool;
      default = false;
      description = "`BB_TELEMETRY`: anonymous usage statistics (PostHog). Off by default here; BB's own default is on.";
    };

    claudeCode = {
      executable = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/var/lib/bb/.local/bin/claude";
        description = ''
          `BB_CLAUDE_CODE_EXECUTABLE`: full path of the `claude` binary. It must exist and be executable when
          a Claude Code thread starts (BB refuses otherwise). Unset, BB looks for `claude` on the thread's PATH.
        '';
      };

      nativeInstaller = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Prepare the host for Anthropic's native installer (`curl -fsSL https://claude.ai/install.sh | bash`,
          run once as the service user): enables `programs.nix-ld` for the generic glibc binary it fetches
          and puts `~/.local/bin` on login PATHs.
        '';
      };
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.gh pkgs.ripgrep pkgs.fd ]";
      description = ''
        Tools for the agents. They go in the service user's profile (its login PATH, which is where BB
        looks) and on the unit's PATH. Put the Codex CLI here: `bb-nix.packages.x86_64-linux.codex-npm-bin`.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        BB_LOG_LEVEL = "debug";
      };
      description = ''
        More environment for the unit. Never secrets: they would be world-readable in the Nix store; use
        `environmentFile`. Do not also set these with `bb-app env set`: BB's own `env.json` wins over the
        unit.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/bb.env";
      description = ''
        A file of `NAME=value` lines read at start (systemd `EnvironmentFile`), for secrets such as
        `CLAUDE_CODE_OAUTH_TOKEN`. The path is not copied to the store.
      '';
    };

    memoryHigh = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "2560M";
      description = "systemd `MemoryHigh` for the unit, agents included (they run in its cgroup).";
    };

    memoryMax = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "3G";
      description = "systemd `MemoryMax` for the unit, agents included.";
    };

    tailscaleServe = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Publish BB on this node's tailnet name over HTTPS with `tailscale serve` (one unit per port).
          Needs `services.tailscale` and HTTPS certificates enabled for the tailnet. Never funnel: that
          would put an unauthenticated command-execution API on the internet.
        '';
      };

      ports = mkOption {
        type = types.listOf types.port;
        default = [ 443 ];
        example = [
          443
          38443
        ];
        description = "HTTPS ports to serve this backend on. A second port is handy for machine daemons.";
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open `port` in the firewall. Only meaningful with `bindHost = "0.0.0.0"` on a LAN you trust;
        `tailscale serve` needs no firewall change.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.meta.availableOn pkgs.stdenv.hostPlatform cfg.package;
        message = "services.bb.package is not available on ${pkgs.stdenv.hostPlatform.system}.";
      }
      {
        assertion = cfg.tailscaleServe.enable -> config.services.tailscale.enable;
        message = "services.bb.tailscaleServe needs services.tailscale.enable.";
      }
      {
        assertion =
          cfg.tailscaleServe.enable
          -> (cfg.tailscaleServe.ports != [ ] && lib.unique cfg.tailscaleServe.ports == cfg.tailscaleServe.ports);
        message = "services.bb.tailscaleServe.ports must be a non-empty list without duplicates.";
      }
      {
        assertion = cfg.openFirewall -> cfg.bindHost == "0.0.0.0";
        message = "services.bb.openFirewall only makes sense with bindHost = \"0.0.0.0\".";
      }
      {
        assertion = lib.hasPrefix "/" cfg.dataDir && !(lib.hasSuffix "/" cfg.dataDir);
        message = "services.bb.dataDir must be an absolute path without a trailing slash.";
      }
      {
        assertion = cfg.hostDaemonPort != cfg.port;
        message = "services.bb.port and services.bb.hostDaemonPort must differ.";
      }
    ];

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      homeMode = "0700";
      # BB probes each thread's environment with `$SHELL -ilc env` (3 s limit), so the user needs a real
      # login shell and its tools in its profile.
      shell = pkgs.bashInteractive;
      packages = cfg.extraPackages;
    };

    # `bb` (the CLI) and `bb-app` for administration: `sudo -u bb -H bb settings ...`.
    environment.systemPackages = [ cfg.package ];

    programs.nix-ld.enable = mkIf cfg.claudeCode.nativeInstaller (lib.mkDefault true);
    environment.localBinInPath = mkIf cfg.claudeCode.nativeInstaller (lib.mkDefault true);

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];

    systemd.services = {
      bb = {
        description = "BB: server, web UI and local host daemon";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          cfg.nodejs
          pkgs.git
          pkgs.openssh
          pkgs.coreutils
          pkgs.bash
        ]
        ++ cfg.extraPackages;
        environment = {
          HOME = cfg.dataDir;
          BB_DATA_DIR = cfg.dataDir;
          BB_TELEMETRY = lib.boolToString cfg.telemetry;
        }
        // optionalAttrs (cfg.appUrl != null) { BB_APP_URL = cfg.appUrl; }
        // optionalAttrs (cfg.externalUrl != null) { BB_EXTERNAL_URL = cfg.externalUrl; }
        // optionalAttrs (cfg.claudeCode.executable != null) {
          BB_CLAUDE_CODE_EXECUTABLE = cfg.claudeCode.executable;
        }
        // cfg.environment;

        serviceConfig = {
          # --no-in-app-updates: the program lives in the read-only Nix store, so bb must not try to swap
          # itself for a newer npm install; the version changes with the flake.
          ExecStart = lib.escapeShellArgs [
            "${cfg.package}/bin/bb-app"
            "--no-in-app-updates"
            "--data-dir"
            cfg.dataDir
            "--server-bind-host"
            cfg.bindHost
            "--server-port"
            (toString cfg.port)
            "--host-daemon-port"
            (toString cfg.hostDaemonPort)
          ];
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.dataDir;
          Restart = "on-failure";
          RestartSec = 5;
          # bb-app restarts its children itself; on stop let it shut them down before the cgroup is killed.
          KillMode = "mixed";
          TimeoutStopSec = 30;
          # Hardening is deliberately light. The agents are the product: they need a normal home, git, ssh,
          # a writable /tmp, and they may run sudo-less system tools. The user is dedicated and
          # unprivileged, and that is the whole boundary.
        }
        // optionalAttrs underVarLib {
          StateDirectory = lib.removePrefix "/var/lib/" cfg.dataDir;
          StateDirectoryMode = "0700";
        }
        // optionalAttrs (cfg.environmentFile != null) { EnvironmentFile = cfg.environmentFile; }
        // optionalAttrs (cfg.memoryHigh != null) { MemoryHigh = cfg.memoryHigh; }
        // optionalAttrs (cfg.memoryMax != null) { MemoryMax = cfg.memoryMax; };
      };
    }
    // lib.listToAttrs (
      map (
        port:
        lib.nameValuePair (serveUnitName port) {
          description = "Serve BB on the tailnet over HTTPS port ${toString port}";
          after = [
            "tailscaled.service"
            "bb.service"
          ];
          wants = [ "bb.service" ];
          bindsTo = [ "tailscaled.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStartPre = "${pkgs.coreutils}/bin/timeout 120 ${pkgs.bash}/bin/sh -c 'until ${tailscale}/bin/tailscale status >/dev/null 2>&1; do sleep 1; done'";
            # `serve`, never `funnel`.
            ExecStart = "${tailscale}/bin/tailscale serve --bg --https=${toString port} http://127.0.0.1:${toString cfg.port}";
            ExecStop = "${tailscale}/bin/tailscale serve --https=${toString port} off";
          };
        }
      ) (lib.optionals cfg.tailscaleServe.enable cfg.tailscaleServe.ports)
    );
  };
}
