{ pkgs, nixosModule, idrive-client }:

pkgs.testers.runNixOSTest {
  name = "idrive-user-service";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ nixosModule ];
    virtualisation.diskSize = 4096;

    users.users.alice = { isNormalUser = true; };
    users.users.bob = { isNormalUser = true; };

    # alice is listed, bob is not. bob exists precisely so the gate has
    # something to exclude: a test where every user is allowed cannot tell
    # a working ConditionUser from an absent one.
    services.idrive = {
      package = idrive-client;
      userServices = [ "alice" ];
      timeZone = "Etc/UTC";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Lingering is what keeps a user manager running with nobody logged in.
    # Without it the service would exist and simply never run outside a
    # session, which is the failure this asserts against.
    machine.wait_until_succeeds("loginctl show-user alice -p Linger --value | grep -qx yes")

    alice_uid = machine.succeed("id -u alice").strip()
    bob_uid = machine.succeed("id -u bob").strip()

    def user_systemctl(uid, args):
        return (
            f"systemd-run --uid={uid} --pipe --wait --quiet"
            f" --setenv=XDG_RUNTIME_DIR=/run/user/{uid}"
            f" -- systemctl --user {args}"
        )

    machine.wait_until_succeeds(f"test -d /run/user/{alice_uid}")

    # The unit is defined for every user on the machine (systemd.user units
    # always are), so its presence proves nothing on its own. What matters
    # is which users it is permitted to start for.
    machine.succeed(user_systemctl(alice_uid, "cat idrive.service"))

    # ConditionUser, verified rather than assumed. systemd.unit(5) says
    # repeated conditions of the same type are ANDed, and that a pipe
    # prefix makes them triggering (ORed). If the module ever emits plain
    # ConditionUser= lines again, a second listed user would make every
    # start silently skip, so assert the mechanism here, not just that the
    # service happened to run.
    machine.succeed(user_systemctl(alice_uid, "start idrive.service"))
    machine.wait_until_succeeds(
        user_systemctl(alice_uid, "show idrive.service -p ConditionResult --value")
        + " | grep -qx yes"
    )

    # bob is not listed: the condition must reject him. A skipped unit is
    # reported as a failed condition, not as an error, so check the
    # condition result rather than the start command's exit status.
    machine.succeed("loginctl enable-linger bob")
    machine.wait_until_succeeds(f"test -d /run/user/{bob_uid}")
    machine.succeed(user_systemctl(bob_uid, "start idrive.service") + " || true")
    machine.succeed(
        user_systemctl(bob_uid, "show idrive.service -p ConditionResult --value")
        + " | grep -qx no"
    )

    # State landed in alice's own home, under XDG_STATE_HOME's default, and
    # is owned by her. This is the whole point of the per-user shape: no
    # capability, no shared state directory, no root.
    machine.wait_until_succeeds("test -d /home/alice/.local/state/idrive")
    machine.succeed("stat -c %U /home/alice/.local/state/idrive | grep -qx alice")
    machine.succeed("test -f /home/alice/.local/state/idrive/.app/idrive")
    machine.succeed(
        "grep -qx /home/alice/.local/state/idrive"
        " /home/alice/.local/state/idrive/.app/.serviceLocation"
    )

    # bob got nothing.
    machine.fail("test -e /home/bob/.local/state/idrive")

    # The interactive per-user command is idrive-user, deliberately not
    # idrive, so a machine can run both shapes without the name meaning
    # different things to different people.
    setup = machine.succeed(
        "runuser -u alice -- timeout 300 idrive-user --account-setting < /dev/null 2>&1; true"
    )
    assert "Login using IDrive credentials" in setup, (
        f"idrive-user --account-setting never reached its login prompt: {setup}"
    )

    # Only the client writes under user_profile/, and it keys the profile by
    # invoking user: direct evidence that a per-user client resolved its
    # service path into alice's own state directory.
    machine.succeed("test -d /home/alice/.local/state/idrive/user_profile/alice")

    # The self-update block still holds through the per-user entry point.
    machine.fail("runuser -u alice -- idrive-user --check-update")
  '';
}
