# NixOS VM test: boots services.bb under systemd, waits for /health and runs the CLI as the service
# user. Needs /dev/kvm, so the Forgejo runner skips it (the smoke and module-eval checks cover CI);
# run it on a machine with KVM: `nix build .#checks.x86_64-linux.vm`.
{
  testers,
  bbModules,
  bb-app-bin,
}:
testers.runNixOSTest {
  name = "bb";
  nodes.machine =
    { ... }:
    {
      imports = [ bbModules ];
      services.bb = {
        enable = true;
        package = bb-app-bin;
      };
      virtualisation.memorySize = 2048;
    };
  testScript = ''
    machine.wait_for_unit("bb.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:38886/health", timeout=180)
    # The service user's login PATH has the CLI (environment.systemPackages), and BB runs from the store.
    machine.succeed("sudo -u bb -H bb --version")
    machine.wait_until_succeeds("sudo -u bb -H env BB_DATA_DIR=/var/lib/bb BB_SERVER_URL=http://127.0.0.1:38886 bb machine list --json | grep -q .")
    machine.succeed("systemctl is-active bb.service")
  '';
}
