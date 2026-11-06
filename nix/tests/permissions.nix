{ pkgs, nixosModule, idrive-client }:

pkgs.testers.runNixOSTest {
  name = "idrive-permissions";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ nixosModule ];
    virtualisation.diskSize = 4096;

    # A group the service user joins, owning data that is group-readable,
    # and a file readable only by root. The first is what supplementaryGroups
    # is for; the second is what readAllFiles is for.
    users.groups.backupdata = { };
    users.users.alice = { isNormalUser = true; };

    systemd.tmpfiles.rules = [
      "d /srv/shared 0750 root backupdata -"
      "f /srv/shared/groupreadable 0640 root backupdata - group-readable"
      "d /srv/secret 0700 root root -"
      "f /srv/secret/data 0600 root root - root-only"
    ];

    services.idrive = {
      enable = true;
      acceptTerms = true;
      package = idrive-client;
      user = "idrive";
      group = "idrive";
      createUser = true;
      supplementaryGroups = [ "backupdata" ];
      readAllFiles = true;
      scheduledBackup.enable = true;
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

    # Unlike nix/tests/native.nix this daemon cannot stay up: the client's
    # scheduler has `exit(0) if ($AppConfig::mcUser ne 'root')`. So a non-root
    # service never runs a schedule, and Result=success is all there is.
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
    machine.succeed("systemctl show idrive.service -p UMask --value | grep -qx 0077")
    machine.succeed("systemctl show idrive-backup.service -p UMask --value | grep -qx 0077")
    machine.succeed("systemctl list-timers --all | grep -q idrive-backup.timer")

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
    # this: it exits at once for any user but root.
    machine.succeed("test -d /var/lib/idrive/user_profile/idrive")
    machine.succeed("stat -c %U /var/lib/idrive/user_profile/idrive | grep -qx idrive")

    # Now the part that matters: prove the view, rather than trusting that a
    # unit property implies an effect.
    #
    # Baseline. As the service user outside the units, a 0600 root-owned file
    # is unreadable and a 0700 root-owned directory is unsearchable. If these
    # ever start succeeding, the test below proves nothing.
    machine.fail("runuser -u idrive -- cat /srv/secret/data")
    machine.fail("runuser -u idrive -- ls /srv/secret")

    machine.succeed("systemctl start idrive-read-view.service")
    in_view = (
        "systemd-run --wait --pipe --quiet --uid=idrive"
        " --property=BindReadOnlyPaths=/run/idrive-view/srv/secret:/srv/secret"
        " --property=NoNewPrivileges=yes -- "
    )

    # The client's own test is Perl -r, which reads the mode bits. cat alone is
    # not enough: a capability passes cat and fails this.
    assert "root-only" in machine.succeed(in_view + "cat /srv/secret/data")
    machine.succeed(
        in_view + "${pkgs.perl}/bin/perl -e 'exit(-r $ARGV[0] ? 0 : 1)' /srv/secret/data"
    )

    # Reading is all it gives.
    machine.fail(in_view + "sh -c 'echo tampered > /srv/secret/data'")
    machine.succeed("grep -qx root-only /srv/secret/data")

    # It changes nothing on the real file, and nobody else can reach it, the
    # service user included: only the units have it, through the bind.
    assert machine.succeed("stat -c '%a %U' /srv/secret/data").strip() == "600 root"
    machine.fail("runuser -u alice -- cat /run/idrive-view/srv/secret/data")
    machine.fail("runuser -u idrive -- cat /run/idrive-view/srv/secret/data")

    # An unlinked machine fails the job instead of reporting success.
    machine.fail("systemctl start idrive-backup.service")
    journal = machine.succeed("journalctl -u idrive-backup -b --no-pager -o cat")
    assert "expected one linked account" in journal, journal

    # The bind reached the real unit, and the client's own view of the set.
    machine.succeed(
        "systemctl show idrive-backup.service -p BindReadOnlyPaths --value"
        " | grep -q /run/idrive-view/srv/secret"
    )

    # supplementaryGroups covers the group-readable case on its own.
    shared = machine.succeed("runuser -u idrive -- cat /srv/shared/groupreadable")
    assert "group-readable" in shared, (
        f"supplementary group did not grant the read: {shared!r}"
    )

    # Self-update still refuses under a non-root user.
    machine.fail("runuser -u idrive -- idrive --check-update")
  '';
}
