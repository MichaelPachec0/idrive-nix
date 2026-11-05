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
      acceptTerms = true;
      package = idrive-client;
      # The second entry never exists: an unplugged disk must not stop the
      # service, which the is-active check below would catch.
      backupPaths = [ "/srv/data" "/srv/not-plugged-in" ];
      writablePaths = [ "/srv/also-not-plugged-in" ];
      legacySourceLinks = true;
      timeZone = "Etc/UTC";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # The daemon runs with or without a linked account, so it has to still be
    # running below. It used to exit within seconds, which looked like a
    # precondition in the client and was really its lock failing.
    machine.succeed("systemctl start idrive.service")
    machine.wait_until_succeeds(
        "systemctl show idrive.service --property=Result --value | grep -qx success"
    )
    machine.fail("systemctl is-failed idrive.service")

    # The scheduler exits 0 when it cannot open its lock, so Result=success
    # above cannot see this. On a linked account it stops the daemon dead.
    machine.fail("journalctl -u idrive.service | grep -qE 'idrivecron.lock|flock\\(\\)'")
    machine.sleep(15)
    machine.succeed("systemctl is-active idrive.service")

    # A clock jump, as after a suspend, makes the scheduler exit 0 and expect
    # a distro service template to restart it. It has to come back anyway.
    machine.succeed("date -s '+3 hours'")
    machine.wait_until_succeeds(
        "[ \"$(systemctl show idrive.service --property=NRestarts --value)\" -ge 1 ]",
        timeout=120,
    )
    machine.wait_until_succeeds("systemctl is-active idrive.service", timeout=60)

    # Backups stop at "Unable to find MAC Address" without these, and that
    # needs a linked account to reach, so assert the wrapper's PATH instead.
    machine.succeed("grep -q -- '-which-' /var/lib/idrive/.app/idrive")
    machine.succeed("grep -q -- '-net-tools-' /var/lib/idrive/.app/idrive")

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

    # The vendored Python helper has to resolve the service path from its
    # own location, so it only works if Idrivelib is mirrored into the
    # application directory rather than symlinked into the store (see
    # nix/start.nix). When it cannot, every authentication fails with
    # "'helpers' object has no attribute '_helpers__servicepath'" and no
    # account can ever be linked.
    #
    # Driving setup with a username that cannot exist reaches the helper
    # without any credentials, which is what makes this assertable in CI:
    # the run is expected to fail, and what matters is which failure. Stdin
    # is a pipe here, so the helper refuses it locally with Invalid_arguments
    # and no request is sent. That still means the helper resolved itself;
    # the servicepath error means it never got that far.
    auth = machine.succeed(
        "printf '1\\nnobody@invalid.example\\n'"
        " | timeout 300 idrive --account-setting --auto-setup 2>&1; true"
    )
    assert "_helpers__servicepath" not in auth, (
        f"the vendored Python helper could not resolve its service path,"
        f" so no login can succeed: {auth}"
    )
    assert "Failed to authenticate" in auth, (
        f"setup did not reach authentication at all: {auth}"
    )

    # The client stamps every request with an OS name and build, taken from
    # /etc/os-release. Its parser needs a newline after VERSION_ID's closing
    # quote, which NixOS does not provide because VERSION_ID is the last
    # line and the client chomps the file first. Without the cat shim it
    # falls through to a branch that sends the HOSTNAME as the operating
    # system with build 0, and IDrive answers Invalid_arguments for every
    # account, valid or not.
    #
    # The client writes what it decided into its own trace log, so this is
    # assertable with no credentials at all.
    trace = machine.succeed(
        "cat /var/lib/idrive/user_profile/root/.trace/traceLog.txt"
    )
    assert "OS details" in trace, f"no OS details line in the trace log: {trace}"
    os_line = [ln for ln in trace.splitlines() if "OS details" in ln][-1]
    assert "nixos" in os_line, (
        f"the client did not identify the OS correctly, so its requests will"
        f" be rejected: {os_line!r}"
    )
    assert "machine" not in os_line, (
        f"the client sent the hostname as its operating system: {os_line!r}"
    )

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
