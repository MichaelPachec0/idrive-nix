{ pkgs, nixosModule, idrive-client }:

pkgs.testers.runNixOSTest {
  name = "idrive-native";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ nixosModule ];
    # allowUnfree is already set on the pkgs instance runNixOSTest is called
    # with (see flake.nix's pkgsFor), and nixpkgs.config is read-only for a
    # test node once that instance is fixed. Redeclaring it here conflicts
    # rather than being redundant.
    virtualisation.diskSize = 4096;

    systemd.tmpfiles.rules = [ "d /srv/data 0755 root root -" ];

    services.idrive = {
      enable = true;
      package = idrive-client;
      backupPaths = [ "/srv/data" ];
      legacySourceLinks = true;
      timeZone = "Etc/UTC";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # idrive --cron exits cleanly, quickly, and on its own the moment it
    # finds no linked IDrive account: that is a real precondition check
    # inside the client itself, not a bug here, and not something any
    # systemd/module setting changes. A backup agent with no account
    # legitimately has nothing to run. CI has no IDrive credentials and
    # never will, so this test cannot assert the unit stays "active" the
    # way a real, account-linked deployment eventually would. Do NOT
    # restore a wait_for_unit("idrive.service") here: that assertion can
    # never pass in this environment, and someone re-adding it will just be
    # reintroducing a permanently red check. Instead assert the part that
    # is actually true: the unit starts cleanly and stops with
    # Result=success, not a crash, and is not left in a failed state.
    machine.succeed("systemctl start idrive.service")
    machine.wait_until_succeeds(
        "systemctl show idrive.service --property=Result --value | grep -qx success"
    )
    machine.fail("systemctl is-failed idrive.service")

    # The only end-to-end exercise of the module's own ExecStart argv0: if
    # this ever prints the client's symlink-guard refusal (see
    # nix/wrappers.nix), the unit is invoking --cron through a path that
    # is not a symlink, and Result=success alone would not catch it, since
    # the guard refusal also exits 0.
    machine.fail(
        "journalctl -u idrive.service | grep -q 'Launch the service using service manager'"
    )

    # ExecStartPre (the prepare step) ran to completion before ExecStart -
    # that ordering is exactly why it is an ExecStartPre and not the first
    # thing ExecStart does: under Type=simple systemd reports the service
    # started as soon as ExecStart is forked, so a prepare step living
    # there would still be running when these assertions fire. State
    # directory created and seeded,
    # including the writable application directory the client resolves its
    # own appPath to (see nix/start.nix).
    machine.succeed("test -d /var/lib/idrive")
    machine.succeed("test -f /var/lib/idrive/idrivecrontab.json")
    machine.succeed("test -f /var/lib/idrive/.idrive-version")
    machine.succeed("test -f /var/lib/idrive/.app/idrive")
    machine.succeed("test ! -L /var/lib/idrive/.app/idrive")
    machine.succeed("test -L /var/lib/idrive/.app/idrivecron")
    machine.succeed("grep -qx /var/lib/idrive /var/lib/idrive/.app/.serviceLocation")

    # The wrapped client is on PATH for interactive account setup.
    machine.succeed("idrive --version")

    # The documented first-run command, run exactly as the README tells an
    # operator to run it, driven only as far as its own authentication menu
    # (no credentials needed, and none exist in CI). Before the writable
    # application directory existed this died with "Cannot open directory
    # <store path> Permission denied" right here.
    setup = machine.succeed(
        "timeout 300 idrive --account-setting < /dev/null 2>&1; true"
    )
    assert "Login using IDrive credentials" in setup, (
        f"idrive --account-setting never reached its login prompt: {setup}"
    )

    # The one assertion in this suite that only the client itself can
    # satisfy: everything under user_profile/ is written by the client, and
    # nothing in the prepare step creates it. It is the direct evidence
    # that the client resolved its service path to stateDir instead of to
    # the store or to its own cwd.
    machine.succeed("test -f /var/lib/idrive/user_profile/root/.trace/traceLog.txt")

    # Self-update must refuse, not partially apply. This is the end-to-end
    # proof of the whole design: the wrapped binary from
    # environment.systemPackages, invoked exactly as an operator would.
    machine.fail("idrive --check-update")

    # Existing backup sets reference /source/N. legacySourceLinks keeps a
    # migrated profile working without re-pointing every set by hand.
    # test -L plus readlink only compares the link text; test -d confirms
    # it actually resolves to the backup path, not just names it.
    machine.succeed("test -L /source/1")
    machine.succeed("readlink /source/1 | grep -x /srv/data")
    machine.succeed("test -d /source/1")
  '';
}
