{ pkgs, nixosModule, idrive-client, idrive-image }:

pkgs.testers.runNixOSTest {
  name = "idrive-container";

  nodes.machine = { ... }: {
    imports = [ nixosModule ];
    virtualisation.diskSize = 6144;

    systemd.tmpfiles.rules = [ "d /srv/data 0755 root root -" ];

    services.idrive = {
      enable = true;
      package = idrive-client;
      backend = "container";
      backupPaths = [ "/srv/data" ];
      container.imageFile = idrive-image;
      # Not Etc/UTC: this is what makes the static "-e TZ=..." check below
      # meaningful - it has to show a value that could only have come from
      # this option, not the image's own baked-in default.
      timeZone = "Europe/Berlin";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # idrive --cron exits cleanly, quickly, and on its own the moment it
    # finds no linked IDrive account - a real precondition check inside the
    # client itself, not a fault in this module (see nix/tests/native.nix,
    # which documents the identical behavior under the native backend).
    # Under the container backend that window is even tighter: direct
    # observation while writing this test showed "container died" landing
    # 0.15-0.4s after "container start", and oci-containers' own postStop
    # hook (podman rm -f, which runs whenever the unit stops for any
    # reason, not only `systemctl stop`) then removes the container within
    # roughly another 150ms - both comfortably faster than any exec or
    # inspect issued from this script after the fact can land. CI has no
    # IDrive credentials and never will, so neither "the container stays
    # up" nor even "podman ps -a still lists it a moment later" can ever
    # hold here; both were tried and both are permanently red on an
    # unconfigured system. Do NOT restore either assertion: what follows
    # is deliberately the version of this test that only claims what is
    # actually true.
    machine.succeed("systemctl start podman-idrive.service")
    machine.wait_until_succeeds(
        "systemctl show podman-idrive.service --property=Result --value | grep -qx success"
    )
    machine.fail("systemctl is-failed podman-idrive.service")

    # log-driver = "journald" (the oci-containers default) tags the
    # container's own stdout/stderr with its name as syslog identifier. If
    # this ever prints the client's symlink-guard refusal (see
    # nix/wrappers.nix), --cron is being invoked through a path that is
    # not a symlink under the container backend specifically -
    # Result=success alone would not catch it, since the guard refusal
    # also exits 0.
    machine.fail(
        "journalctl -t idrive | grep -q 'Launch the service using service manager'"
    )

    # ExecStartPre (the prepare step, shared with the native backend via
    # nix/start.nix) ran inside the container against the bind-mounted
    # state directory. Checking for its two output files here, the same
    # two nix/tests/native.nix checks, is the strongest evidence available
    # that stateDir:/opt/IDriveForLinux/idriveIt actually mapped: it shows
    # the image loaded, the entrypoint ran, and the volume was live, all
    # from the host side, which stays true after the container itself is
    # long gone.
    machine.succeed("test -f /var/lib/idrive/idrivecrontab.json")
    machine.succeed("test -f /var/lib/idrive/.idrive-version")

    # /source/N and TZ cannot be checked against a live process for the
    # reason explained above, so they are asserted from the generated
    # unit's own command line instead. This proves the wiring
    # services.idrive built is correct - that the module actually passes
    # backupPaths and timeZone through to the container's argv - not that
    # a running container observed the effect; that is the honest ceiling
    # of what a script can show here without a linked account. Backup sets
    # configured against the upstream image address /source/N, because
    # that is how the old Docker image mapped them; the container backend
    # must reproduce that layout exactly, or existing backup sets break on
    # migration.
    script_path = machine.succeed(
        "systemctl cat podman-idrive.service | sed -n 's/^ExecStart=//p' | head -n1"
    ).strip()
    unit_script = machine.succeed(f"cat {script_path}")
    assert "/srv/data:/source/1:ro" in unit_script, (
        f"backupPaths not mapped to /source/1:ro in the generated unit "
        f"script:\n{unit_script}"
    )
    assert "-e TZ=Europe/Berlin" in unit_script, (
        f"services.idrive.timeZone not passed through to the container "
        f"env in the generated unit script:\n{unit_script}"
    )
  '';
}
