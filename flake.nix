{
  description = "NixOS modules and packages for BB (github.com/get-bb/bb): a web UI and server for coding agents";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      pkgsX86 = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      packages = forAll (
        pkgs:
        {
          # Built from the committed npm lock (importNpmLock): works wherever nixpkgs does.
          bb-app = pkgs.callPackage ./pkgs/bb-app.nix { };
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.bb-app;
        }
        # Prebuilt downloads, pinned by hash: for hosts that should compile and fetch nothing else.
        // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (
          pkgs.callPackage ./pkgs/prebuilt.nix { }
        )
      );

      nixosModules = {
        bb = ./module.nix;
        bb-host-daemon = ./host-daemon.nix;
        default = {
          imports = [
            ./module.nix
            ./host-daemon.nix
          ];
        };
      };

      overlays.default = final: _prev: {
        bb-app = final.callPackage ./pkgs/bb-app.nix { };
        bb-app-bin = final.callPackage ./pkgs/bb-app-bin.nix { };
        codex-npm-bin = final.callPackage ./pkgs/codex-npm-bin.nix { };
      };

      formatter = forAll (pkgs: pkgs.nixfmt);

      # CI has no KVM: `smoke` and `module-eval` are cheap and run anywhere; `vm` needs /dev/kvm.
      checks.x86_64-linux = {
        smoke = pkgsX86.callPackage ./checks/smoke.nix {
          bb-app = self.packages.x86_64-linux.bb-app-bin;
        };
        module-eval = pkgsX86.callPackage ./checks/module-eval.nix {
          inherit nixpkgs;
          bbModules = self.nixosModules.default;
          bb-app-bin = self.packages.x86_64-linux.bb-app-bin;
          codex-npm-bin = self.packages.x86_64-linux.codex-npm-bin;
        };
        vm = pkgsX86.callPackage ./checks/vm.nix {
          bbModules = self.nixosModules.default;
          bb-app-bin = self.packages.x86_64-linux.bb-app-bin;
        };
      };
    };
}
