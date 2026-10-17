# services.bb-host-daemon: a BB host daemon on this machine, joined to a BB server elsewhere, so the
# server can run agent threads here. Use it on every machine except the one running services.bb (that
# one already has a daemon).
#
# Enrolment is a one-time step the module cannot do for you, because the server hands out a credential
# that expires after 15 minutes: add the machine in the BB web UI (Settings, Machines, Manual) and run
# `bb machine enroll --bootstrap-env BB_ENROLLMENT` as the daemon's user with BB_DATA_DIR set to
# `dataDir`. The unit waits for the resulting `auth.json` and then keeps the daemon running. README.md
# has the commands.
#
#   inputs.bb-nix.url = "github:djbclark/bb-nix";
#   imports = [ inputs.bb-nix.nixosModules.default ];
#   services.bb-host-daemon = { enable = true; serverUrl = "https://bb.example.ts.net:38443"; };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.bb-host-daemon;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    types
    ;

  # systemd's StateDirectory manages the data dir only for a user the module creates and a path under
  # /var/lib. For an existing user the module never creates, chowns or chmods anything: `bb machine
  # enroll`, run as that user, makes the directory (mode 0700) and `auth.json`.
  underVarLib = lib.hasPrefix "/var/lib/" cfg.dataDir;
  useStateDirectory = cfg.createUser && underVarLib;

  # scheme://host[:port][/path]  ->  [ host port-or-null path-or-null ]
  urlParts = builtins.match "https?://([^/:]+)(:[0-9]+)?(/.*)?" cfg.serverUrl;
  serverHost = if urlParts == null then null else builtins.elemAt urlParts 0;

  # "host:port" -> { host, port }
  splitHostPort =
    s:
    let
      m = builtins.match "([^:]+):([0-9]+)" s;
    in
    if m == null then null else {
      host = builtins.elemAt m 0;
      port = builtins.elemAt m 1;
    };
  proxy = splitHostPort cfg.forwarder.proxy;
  target = if cfg.forwarder.target == null then null else splitHostPort cfg.forwarder.target;
in
{
  options.services.bb-host-daemon = {
    enable = mkEnableOption "a BB host daemon that serves a remote BB server (enrol it once by hand first)";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./pkgs/bb-app.nix { };
      defaultText = lib.literalMD "`bb-app` built from the committed npm lock";
      description = ''
        Package providing `bin/bb-host-daemon` and `bin/bb`. Use the same version as the server: the
        server refuses or upgrades daemons with a different protocol.
      '';
    };

    nodejs = mkOption {
      type = types.package;
      default = pkgs.nodejs_24;
      defaultText = lib.literalExpression "pkgs.nodejs_24";
      description = "Node.js on the daemon's PATH.";
    };

    serverUrl = mkOption {
      type = types.str;
      example = "https://bb.example.ts.net:38443";
      description = ''
        `--server-url`: the BB server. It must be exactly the URL the machine was enrolled against (the
        daemon refuses a different one).
      '';
    };

    user = mkOption {
      type = types.str;
      default = "bb";
      description = ''
        The user the daemon and every agent thread on this machine run as. Agents get its files, keys and
        credentials, and sudo if it has it.
      '';
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Create `user` as a system user (home = `dataDir`, group = `user`). Set it to false to run the
        agents as a user you already have; the module then touches nothing of that user, not even its
        home directory.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/bb-host";
      description = ''
        `--data-dir`: the daemon's identity (`auth.json`, `host-id`, `config.json`), logs and agent
        worktrees. With `createUser = false` it may be anywhere the user can write (for example a
        persistent volume); the module does not create or touch it, enrolment does.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 38888;
      description = "`--host-daemon-port`: the daemon's loopback API port.";
    };

    ldPreload = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/current-system/sw/lib/portshim.so";
      description = ''
        A library for the daemon's `LD_PRELOAD`, for example the loopback-port-shim that works around
        libkrun's TSI sockets inside a microVM (see the README).
      '';
    };

    npmGlobalPrefix = mkOption {
      type = types.nullOr types.str;
      default = if cfg.createUser then "${cfg.dataDir}/.local" else null;
      defaultText = lib.literalMD "`\"\${dataDir}/.local\"` when the module creates the user, else `null`";
      example = "/home/agent/.local";
      description = ''
        Where `npm install -g` puts packages for the agents' user (BB's agent installer runs it; on NixOS
        npm's default prefix is the read-only Node.js store path and the install fails). When set, the module
        sets `NPM_CONFIG_PREFIX` in the unit and in that user's login shells, and puts `<prefix>/bin` first
        on both PATHs. See `services.bb.npmGlobalPrefix`, which this mirrors. For an existing user
        (`createUser = false`) the default is `null`, because the module does not know or touch that user's
        home: set it to a directory that user can write, for example `~/.local`, or set `NPM_CONFIG_PREFIX`
        in that user's own shell profile. Either way that user needs Node.js on its login PATH (the module adds
        it to a created user's profile only).
      '';
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Tools for the agents, on the unit's PATH and, with `createUser`, in the new user's profile. For an
        existing user, install them in that user's own profile: BB reads each thread's PATH from the
        user's login shell.
      '';
    };

    forwarder = {
      enable = mkEnableOption "a loopback forwarder (socat) that reaches the BB server through an HTTP CONNECT proxy, for hosts whose Tailscale runs in userspace and has no tailnet interface";

      listenPort = mkOption {
        type = types.port;
        default = 38443;
        description = "Loopback port the daemon connects to. Match it in `serverUrl`.";
      };

      proxy = mkOption {
        type = types.str;
        default = "127.0.0.1:1055";
        description = "`host:port` of the HTTP CONNECT proxy (tailscaled's `--outbound-http-proxy-listen`).";
      };

      target = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "bb.example.ts.net:38443";
        description = "`host:port` of the BB server as the proxy should reach it. Required with `forwarder.enable`.";
      };
    };

    hostsEntry = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Map the host name of `serverUrl` to 127.0.0.1 in /etc/hosts, so that with the forwarder the daemon
        keeps using the server's real name (its TLS certificate matches) while its traffic goes through
        the loopback listener.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.meta.availableOn pkgs.stdenv.hostPlatform cfg.package;
        message = "services.bb-host-daemon.package is not available on ${pkgs.stdenv.hostPlatform.system}.";
      }
      {
        assertion = urlParts != null;
        message = "services.bb-host-daemon.serverUrl must look like https://host[:port]";
      }
      {
        assertion = lib.hasPrefix "/" cfg.dataDir && !(lib.hasSuffix "/" cfg.dataDir);
        message = "services.bb-host-daemon.dataDir must be an absolute path without a trailing slash.";
      }
      {
        assertion = cfg.npmGlobalPrefix == null || lib.hasPrefix "/" cfg.npmGlobalPrefix;
        message = "services.bb-host-daemon.npmGlobalPrefix must be an absolute path (or null).";
      }
      {
        assertion = cfg.forwarder.enable -> (proxy != null && target != null);
        message = "services.bb-host-daemon.forwarder needs proxy = \"host:port\" and target = \"host:port\".";
      }
      {
        assertion = !(lib.attrByPath [ "services" "bb" "enable" ] false config);
        message = "services.bb already runs a host daemon on this machine; enable services.bb-host-daemon only on other machines.";
      }
      {
        assertion = cfg.createUser -> cfg.user != "root";
        message = "services.bb-host-daemon.user must not be root.";
      }
    ];

    users.groups = mkIf cfg.createUser { ${cfg.user} = { }; };
    users.users = mkIf cfg.createUser {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.user;
        home = cfg.dataDir;
        createHome = true;
        homeMode = "0700";
        shell = pkgs.bashInteractive;
        # Node.js too with an npm prefix: npm-installed agents run by `#!/usr/bin/env node`.
        packages = cfg.extraPackages ++ lib.optional (cfg.npmGlobalPrefix != null) cfg.nodejs;
      };
    };

    environment.systemPackages = [ cfg.package ];

    # Login shells of the agents' user get the npm prefix (see services.bb for why extraInit, and why a
    # guard on the user name instead of a file in the home directory).
    environment.extraInit = mkIf (cfg.npmGlobalPrefix != null) ''
      if [ "$(${pkgs.coreutils}/bin/id -un 2>/dev/null)" = ${lib.escapeShellArg cfg.user} ]; then
        export NPM_CONFIG_PREFIX=${lib.escapeShellArg cfg.npmGlobalPrefix}
        export PATH=${lib.escapeShellArg cfg.npmGlobalPrefix}/bin:"$PATH"
      fi
    '';

    networking.hosts = mkIf (cfg.hostsEntry && serverHost != null) { "127.0.0.1" = [ serverHost ]; };

    systemd.services.bb-host-daemon = {
      description = "BB host daemon";
      after = [ "network-online.target" ] ++ lib.optional cfg.forwarder.enable "bb-tailnet-forward.service";
      wants = [ "network-online.target" ] ++ lib.optional cfg.forwarder.enable "bb-tailnet-forward.service";
      wantedBy = [ "multi-user.target" ];
      # A plain string in `path` is a directory whose bin/ is added: the npm global prefix, first.
      path =
        lib.optional (cfg.npmGlobalPrefix != null) cfg.npmGlobalPrefix
        ++ [
          cfg.nodejs
          pkgs.git
          pkgs.openssh
          pkgs.coreutils
          pkgs.bash
        ]
        ++ cfg.extraPackages;
      environment = {
        BB_DATA_DIR = cfg.dataDir;
      }
      // optionalAttrs (cfg.npmGlobalPrefix != null) { NPM_CONFIG_PREFIX = cfg.npmGlobalPrefix; }
      # With an existing user, HOME stays what the user database says (systemd sets it for User=).
      // optionalAttrs cfg.createUser { HOME = cfg.dataDir; }
      // optionalAttrs (cfg.ldPreload != null) { LD_PRELOAD = toString cfg.ldPreload; };

      unitConfig = {
        # Not enrolled yet: stay inactive (not failed) until `bb machine enroll` has written auth.json.
        ConditionPathExists = "${cfg.dataDir}/auth.json";
      };

      serviceConfig = {
        # No --auto-update: the version changes with the flake, not behind its back.
        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/bb-host-daemon"
          "--data-dir"
          cfg.dataDir
          "--host-daemon-port"
          (toString cfg.port)
          "--server-url"
          cfg.serverUrl
        ];
        User = cfg.user;
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = 5;
        KillMode = "mixed";
        TimeoutStopSec = 30;
      }
      // optionalAttrs cfg.createUser { Group = cfg.user; }
      // optionalAttrs useStateDirectory {
        StateDirectory = lib.removePrefix "/var/lib/" cfg.dataDir;
        StateDirectoryMode = "0700";
      }
      ;
    };

    systemd.services.bb-tailnet-forward = mkIf cfg.forwarder.enable {
      description = "Forward loopback to the BB server through an HTTP CONNECT proxy";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        # PROXY:<proxy host>:<target host>:<target port>,proxyport=<proxy port>
        ExecStart = lib.escapeShellArgs [
          "${pkgs.socat}/bin/socat"
          "TCP-LISTEN:${toString cfg.forwarder.listenPort},bind=127.0.0.1,fork,reuseaddr"
          "PROXY:${proxy.host}:${target.host}:${target.port},proxyport=${proxy.port}"
        ];
        DynamicUser = true;
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
