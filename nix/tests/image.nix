{ pkgs, idrive-image }:

pkgs.testers.runNixOSTest {
  name = "idrive-image";

  nodes.machine = { ... }: {
    virtualisation.podman.enable = true;
    virtualisation.diskSize = 6144;
    environment.systemPackages = [ pkgs.podman ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("podman load < ${idrive-image}")
    machine.succeed("podman run --rm idrive-docker:latest idrive --version")
    machine.fail("podman run --rm idrive-docker:latest idrive --check-update")

    # End-to-end proof that the default entrypoint (no command override,
    # exactly how the container runs in production) satisfies the client's
    # own cron symlink guard (see nix/wrappers.nix). A bare `exec idrive
    # --cron` resolved through PATH would fabricate a nonexistent
    # $PWD/idrive path, trip the guard, print this exact message, and exit 0
    # - looking like a healthy but silently no-op container. Capture the
    # real default-entrypoint invocation's output and assert the message is
    # absent; "; true" keeps machine.succeed from raising on idrive --cron's
    # own exit code, which is not what this assertion is about.
    result = machine.succeed(
        "timeout 15 podman run --rm idrive-docker:latest 2>&1; true"
    )
    assert "Launch the service using service manager" not in result, (
        f"cron symlink guard fired: {result}"
    )
  '';
}
