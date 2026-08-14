{ pkgs, nixosModule, idrive-client }:

pkgs.testers.runNixOSTest {
  name = "idrive-permissions";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ nixosModule ];
    virtualisation.diskSize = 4096;

    # A group the service user joins, owning data that is group-readable,
    # and a file readable only by root. The first is what supplementaryGroups
    # is for; the second is what nothing but CAP_DAC_READ_SEARCH (or root)
    # can read.
    users.groups.backupdata = { };

    systemd.tmpfiles.rules = [
      "d /srv/shared 0750 root backupdata -"
      "f /srv/shared/groupreadable 0640 root backupdata - group-readable"
      "d /srv/secret 0700 root root -"
      "f /srv/secret/data 0600 root root - root-only"
    ];

    services.idrive = {
      enable = true;
      package = idrive-client;
      user = "idrive";
      group = "idrive";
      createUser = true;
      supplementaryGroups = [ "backupdata" ];
      readAllFiles = true;
      umask = "0077";
      backupPaths = [ "/srv/shared" "/srv/secret" ];
      timeZone = "Etc/UTC";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # createUser actually created the account. Without this the unit fails
    # to start with a bare "Failed to determine user credentials", which is
    # the footgun this option exists to remove.
    machine.succeed("id idrive")
    machine.succeed("id -gn idrive | grep -qx idrive")

    # supplementaryGroups reaches the ACCOUNT, not just the unit. The unit's
    # SupplementaryGroups sets the daemon process's supplementary GIDs
    # directly and never touches /etc/group, so on its own it would leave
    # the documented interactive path (sudo -u idrive idrive
    # --account-setting, which runs outside systemd) without the access the
    # daemon has. This assertion is what caught that: it fails if the module
    # only wires the unit.
    machine.succeed("id -Gn idrive | grep -qw backupdata")

    # Same start/Result assertions as nix/tests/native.nix, and for the same
    # reason: the client exits 0 the moment it finds no linked account, so
    # asserting the unit stays active can never pass in CI. Do NOT replace
    # this with wait_for_unit("idrive.service").
    machine.succeed("systemctl start idrive.service")
    machine.wait_until_succeeds(
        "systemctl show idrive.service --property=Result --value | grep -qx success"
    )
    machine.fail("systemctl is-failed idrive.service")

    # The unit carries the wiring the options claim to produce.
    machine.succeed("systemctl show idrive.service -p User --value | grep -qx idrive")
    machine.succeed(
        "systemctl show idrive.service -p SupplementaryGroups --value | grep -qw backupdata"
    )
    machine.succeed(
        "systemctl show idrive.service -p AmbientCapabilities --value"
        " | grep -qw cap_dac_read_search"
    )
    machine.succeed("systemctl show idrive.service -p UMask --value | grep -qx 0077")

    # The state directory is owned by the service user, not root, so the
    # prepare step and the client can both write it.
    machine.succeed("stat -c %U /var/lib/idrive | grep -qx idrive")

    # The documented first-run command, run as the service user rather than
    # as root, which is what the README tells an operator to do once user is
    # not root. Driven only as far as its own authentication menu; no
    # credentials are needed and none exist in CI.
    setup = machine.succeed(
        "runuser -u idrive -- timeout 300 idrive --account-setting < /dev/null 2>&1; true"
    )
    assert "Login using IDrive credentials" in setup, (
        f"idrive --account-setting as a non-root user never reached its login"
        f" prompt: {setup}"
    )

    # Only the client writes anything under user_profile/, and it keys the
    # profile by the invoking user. So this is the direct evidence that a
    # non-root client resolved its service path into stateDir rather than
    # into the read-only store or its own cwd, and that the state directory
    # is genuinely writable by that user. The daemon alone cannot produce
    # this: it exits before doing any work while no account is linked.
    machine.succeed("test -d /var/lib/idrive/user_profile/idrive")
    machine.succeed("stat -c %U /var/lib/idrive/user_profile/idrive | grep -qx idrive")

    # Now the part that matters: prove the capability, rather than trusting
    # that a unit property implies an effect.
    #
    # Baseline. As the service user with no capability, a 0600 root-owned
    # file is unreadable and a 0700 root-owned directory is unsearchable.
    # If these ever start succeeding, the test below proves nothing, because
    # the read would have worked without the capability anyway.
    machine.fail("runuser -u idrive -- cat /srv/secret/data")
    machine.fail("runuser -u idrive -- ls /srv/secret")

    # Same user, same file, with CAP_DAC_READ_SEARCH ambient, and with
    # NoNewPrivileges=yes set exactly as the real unit sets it. This is the
    # combination the module's comment claims works; assert it rather than
    # assuming ambient capabilities survive NoNewPrivileges.
    granted = machine.succeed(
        "systemd-run --wait --pipe --quiet"
        " --uid=idrive"
        " --property=AmbientCapabilities=CAP_DAC_READ_SEARCH"
        " --property=CapabilityBoundingSet=CAP_DAC_READ_SEARCH"
        " --property=NoNewPrivileges=yes"
        " -- cat /srv/secret/data"
    )
    assert "root-only" in granted, (
        f"CAP_DAC_READ_SEARCH did not grant the read: {granted!r}"
    )

    # The capability grants read and search, and no write. A backup agent
    # needs exactly the first and must not have the second, so assert the
    # absence too: this is the whole argument for preferring it over root.
    machine.fail(
        "systemd-run --wait --pipe --quiet"
        " --uid=idrive"
        " --property=AmbientCapabilities=CAP_DAC_READ_SEARCH"
        " --property=CapabilityBoundingSet=CAP_DAC_READ_SEARCH"
        " --property=NoNewPrivileges=yes"
        " -- sh -c 'echo tampered > /srv/secret/data'"
    )
    machine.succeed("grep -qx root-only /srv/secret/data")

    # supplementaryGroups covers the group-readable case on its own, with no
    # capability involved.
    shared = machine.succeed("runuser -u idrive -- cat /srv/shared/groupreadable")
    assert "group-readable" in shared, (
        f"supplementary group did not grant the read: {shared!r}"
    )

    # Self-update still refuses under a non-root user.
    machine.fail("runuser -u idrive -- idrive --check-update")
  '';
}
