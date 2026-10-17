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
in
runCommand "bb-module-eval" { } ''
  printf '%s\n' ${lib.escapeShellArgs drvs} > $out
''
