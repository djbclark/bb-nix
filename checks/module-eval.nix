# Evaluates a sample NixOS system that uses both modules, as far as the system's derivation
# (`toplevel.drvPath`), without building it. A typo in an option, a missing attribute or a failed
# assertion in module.nix or host-daemon.nix fails this check. Cheap: eval only.
{
  lib,
  runCommand,
  nixpkgs,
  bbModules,
  bb-app-bin,
  codex-npm-bin,
}:
let
  common =
    { ... }:
    {
      imports = [ bbModules ];
      boot.isContainer = true;
      system.stateVersion = "26.05";
      networking.hostName = "bb-eval";
      services.tailscale.enable = true;
      users.users.agent = {
        isNormalUser = true;
      };
    };

  server = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      common
      (
        { pkgs, ... }:
        {
          services.bb = {
            enable = true;
            package = bb-app-bin;
            appUrl = "https://bb.example.ts.net";
            externalUrl = "https://bb.example.ts.net:38443";
            memoryHigh = "2560M";
            memoryMax = "3G";
            extraPackages = [
              codex-npm-bin
              pkgs.ripgrep
            ];
            claudeCode = {
              nativeInstaller = true;
              executable = "/var/lib/bb/.local/bin/claude";
            };
            environmentFile = "/run/secrets/bb.env";
            environment.BB_LOG_LEVEL = "debug";
            tailscaleServe = {
              enable = true;
              ports = [
                443
                38443
              ];
            };
          };
        }
      )
    ];
  };

  # The default package (built from the lock) and a user that already exists, outside /var/lib.
  daemon = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      common
      {
        services.bb-host-daemon = {
          enable = true;
          serverUrl = "https://bb.example.ts.net:38443";
          user = "agent";
          createUser = false;
          dataDir = "/persist/bb";
          ldPreload = "/run/current-system/sw/lib/portshim.so";
          hostsEntry = true;
          forwarder = {
            enable = true;
            target = "bb.example.ts.net:38443";
          };
        };
      }
    ];
  };

  # The same module with a created user, under /var/lib, and the prebuilt package.
  daemonCreated = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      common
      {
        services.bb-host-daemon = {
          enable = true;
          package = bb-app-bin;
          serverUrl = "https://bb.example.ts.net";
        };
      }
    ];
  };

  drvs = map (s: builtins.unsafeDiscardOutputDependency s.config.system.build.toplevel.drvPath) [
    server
    daemon
    daemonCreated
  ];
  # The unit files the modules produce, written out so a review (and the CI log) can read them.
  unitText = sys: name: sys.config.systemd.units.${name}.text;
  units = [
    {
      title = "server: bb.service";
      text = unitText server "bb.service";
    }
    {
      title = "server: bb-tailscale-serve-443.service";
      text = unitText server "bb-tailscale-serve-443.service";
    }
    {
      title = "server: bb-tailscale-serve-38443.service";
      text = unitText server "bb-tailscale-serve-38443.service";
    }
    {
      title = "daemon (existing user, /persist): bb-host-daemon.service";
      text = unitText daemon "bb-host-daemon.service";
    }
    {
      title = "daemon (existing user, /persist): bb-tailnet-forward.service";
      text = unitText daemon "bb-tailnet-forward.service";
    }
    {
      title = "daemon (existing user, /persist): bb-hosts-entry.service";
      text = unitText daemon "bb-hosts-entry.service";
    }
    {
      title = "daemon (created user, /var/lib): bb-host-daemon.service";
      text = unitText daemonCreated "bb-host-daemon.service";
    }
  ];
  # Without the string context, the dump names store paths but does not make this check build them.
  unitDump = builtins.unsafeDiscardStringContext (
    lib.concatMapStrings (u: "===== ${u.title}\n${u.text}\n") units
  );
  hostsDump = daemon.config.networking.hosts."127.0.0.1" or [ ];

  # npmGlobalPrefix: the unit gets NPM_CONFIG_PREFIX and <prefix>/bin on PATH, and the user's login shells
  # get both through /etc/set-environment (environment.extraInit), guarded by the user name.
  inUnit =
    sys: name: needle:
    lib.hasInfix needle (builtins.unsafeDiscardStringContext (unitText sys name));
  extraInit = sys: builtins.unsafeDiscardStringContext sys.config.environment.extraInit;
  expectations = [
    {
      msg = "bb.service has NPM_CONFIG_PREFIX=/var/lib/bb/.local";
      ok = inUnit server "bb.service" "NPM_CONFIG_PREFIX=/var/lib/bb/.local";
    }
    {
      msg = "bb.service PATH has /var/lib/bb/.local/bin";
      ok = inUnit server "bb.service" "/var/lib/bb/.local/bin";
    }
    {
      msg = "login shells of bb get NPM_CONFIG_PREFIX";
      ok =
        lib.hasInfix "NPM_CONFIG_PREFIX=/var/lib/bb/.local" (extraInit server)
        && lib.hasInfix "= bb ]" (extraInit server);
    }
    {
      msg = "the bb user's profile has Node.js (npm-installed agents run by #!/usr/bin/env node)";
      ok = lib.any (p: lib.hasPrefix "nodejs" (p.pname or p.name or "")) server.config.users.users.bb.packages;
    }
    {
      msg = "tailscale serve units retry on an etag mismatch";
      ok =
        inUnit server "bb-tailscale-serve-443.service" "sleep $$i"
        && inUnit server "bb-tailscale-serve-443.service" "serve --https=443 off";
    }
    {
      msg = "host daemon with a created user defaults to /var/lib/bb-host/.local";
      ok = inUnit daemonCreated "bb-host-daemon.service" "NPM_CONFIG_PREFIX=/var/lib/bb-host/.local";
    }
    {
      msg = "in a container, hostsEntry also appends the server name to /etc/hosts at boot (the runtime owns that file)";
      ok =
        lib.hasInfix "grep -qF" daemon.config.systemd.services.bb-hosts-entry.script
        && lib.hasInfix "127.0.0.1 bb.example.ts.net" daemon.config.systemd.services.bb-hosts-entry.script
        && inUnit daemon "bb-host-daemon.service" "bb-hosts-entry.service";
    }
    {
      msg = "bb.service and bb's login shells get SSL_CERT_FILE (NixOS Python stdlib TLS)";
      ok =
        inUnit server "bb.service" "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        && lib.hasInfix "export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" (extraInit server);
    }
    {
      msg = "the host daemon unit gets SSL_CERT_FILE too";
      ok = inUnit daemon "bb-host-daemon.service" "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt";
    }
    {
      msg = "host daemon with an existing user has no npm prefix by default";
      ok =
        !(inUnit daemon "bb-host-daemon.service" "NPM_CONFIG_PREFIX")
        && !(lib.hasInfix "NPM_CONFIG_PREFIX" (extraInit daemon));
    }
  ];
  failed = map (e: e.msg) (lib.filter (e: !e.ok) expectations);
in
lib.throwIf (failed != [ ]) "bb module-eval expectations failed: ${lib.concatStringsSep "; " failed}" (
runCommand "bb-module-eval"
  {
    passAsFile = [ "unitDump" ];
    inherit unitDump;
    extraInit = extraInit server;
    hosts = lib.concatStringsSep " " hostsDump;
  }
  ''
    printf '%s\n' ${lib.escapeShellArgs drvs} > $out
    cat "$unitDumpPath" >> $out
    echo "===== /etc/hosts 127.0.0.1 entries of the existing-user daemon system: $hosts" >> $out
    printf '===== server: environment.extraInit (login shells)\n%s\n' "$extraInit" >> $out
    cat $out
  ''
)
