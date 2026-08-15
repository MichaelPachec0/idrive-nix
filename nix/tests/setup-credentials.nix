{ pkgs, nixosModule, idrive-client }:

pkgs.testers.runNixOSTest {
  name = "idrive-setup-credentials";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ nixosModule ];
    virtualisation.diskSize = 4096;

    # Stands in for whatever a secret manager would place here. The point
    # of the test is the plumbing around the file, not the file's origin.
    systemd.tmpfiles.rules = [
      "f /run/idrive-password 0400 root root - NotARealPassword123"
      "f /run/idrive-username 0400 root root - nobody@invalid.example"
    ];

    # usernameFile rather than username, so the account name is read at
    # setup time instead of baked into a store path. The store is world
    # readable, so a plain string there is visible to every user on the
    # machine; this asserts the file path works, since it is the one the
    # README recommends for a secret manager.
    services.idrive = {
      enable = true;
      package = idrive-client;
      usernameFile = "/run/idrive-username";
      passwordFile = "/run/idrive-password";
      timeZone = "Etc/UTC";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # The credentials cannot be real, so setup must fail. What is asserted
    # is that it fails the RIGHT way: reaching the server and being
    # rejected, rather than hanging on an unanswered prompt or reporting
    # success against a profile it never created.
    machine.wait_until_fails("systemctl is-active idrive-setup.service")
    machine.succeed("systemctl is-failed idrive-setup.service")

    out = machine.succeed("journalctl -u idrive-setup.service --no-pager")

    # The failure has to name the credentials, which only happens once the
    # answers were accepted in the right order and the request reached
    # IDrive. A prompt-order break would fail the profile check instead.
    assert "IDrive rejected the credentials" in out, (
        f"setup did not get as far as an authentication attempt: {out}"
    )

    # The packaging fault this would otherwise mask must not be present.
    assert "_helpers__servicepath" not in out, (
        f"the Python helper could not resolve its service path: {out}"
    )

    # The password must never reach the journal, whatever the client
    # printed. This is the whole reason it goes in on standard input.
    assert "NotARealPassword123" not in out, (
        "the password leaked into the journal"
    )

    # A failed setup must not stamp itself as done, or a later rebuild
    # would skip setup forever and leave a machine that never registers.
    machine.fail("test -e /var/lib/idrive/.setup-done")

    # And the daemon must not have started against an unconfigured profile:
    # idrive.service requires the setup unit, so a failed setup keeps it
    # from running rather than leaving it to exit cleanly and look fine.
    machine.fail("systemctl is-active idrive.service")

    # The password file itself is untouched and still unreadable to others.
    machine.succeed("test -f /run/idrive-password")
    machine.succeed("stat -c %a /run/idrive-password | grep -qx 400")

    # usernameFile keeps the account name out of the world-readable store,
    # which is the only thing it promises. Assert that promise directly
    # rather than trusting that reading a file implies it.
    setup_script = machine.succeed(
        "systemctl cat idrive-setup.service"
        " | sed -n 's/^ExecStart=//p' | head -n1"
    ).strip()
    machine.fail(f"grep -q nobody@invalid.example {setup_script}")

    # And it is genuinely read at runtime: the rejection names the account,
    # which it could only have learned from the file.
    assert "nobody@invalid.example" in out, (
        f"the username file was not read: {out}"
    )
  '';
}
