{ pkgs, idrive-image }:

let
  # dockerTools.buildLayeredImage exposes the name and tag it was actually
  # built with as passthru attributes; use those rather than hardcoding a
  # tag string here, so this test cannot drift from nix/image.nix's own
  # `tag = idrive-client.version` (not "latest": see the comment there for
  # why a fixed tag is the wrong choice for a container backend that reads
  # this image).
  image = "${idrive-image.imageName}:${idrive-image.imageTag}";
in
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
    machine.succeed("podman run --rm ${image} idrive --version")
    machine.fail("podman run --rm ${image} idrive --check-update")

    # End-to-end proof that the default entrypoint (no command override,
    # exactly how the container runs in production) satisfies the client's
    # own cron symlink guard (see nix/wrappers.nix). "idrive" resolves
    # through PATH to the image's /bin/idrive symlink, and the shell doing
    # that lookup hands execve(2) the resulting absolute path, so the
    # wrapper's ordinary absolute-path $0 handling is what runs here - not
    # a special case. This test is the end-to-end confirmation of that;
    # nix/wrappers.nix and nix/tests/package-cron-guard.nix cover the
    # mechanism itself at the package level. Capture the real
    # default-entrypoint invocation's output and assert the guard's
    # refusal message is absent; "; true" keeps machine.succeed from
    # raising on idrive --cron's own exit code, which is not what this
    # assertion is about.
    result = machine.succeed(
        "timeout 15 podman run --rm ${image} 2>&1; true"
    )
    assert "Launch the service using service manager" not in result, (
        f"cron symlink guard fired: {result}"
    )
  '';
}
