{ pkgs, nixosModule, idrive-client }:

# The client restores everything as 0777 root:root and drops symlinks, as seen
# against the real service. That result is imitated here so the tools can be
# tested without an account.
pkgs.testers.runNixOSTest {
  name = "idrive-permission-manifest";

  nodes.machine = { ... }: {
    imports = [ nixosModule ];
    virtualisation.diskSize = 4096;
    users.users.alice.isNormalUser = true;
    services.idrive = {
      enable = true;
      acceptTerms = true;
      package = idrive-client;
      timeZone = "Etc/UTC";
      permissionManifest.paths = [ "/srv/tree" "/srv/not-plugged-in" ];
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    machine.succeed(
        "mkdir -p /srv/tree/sub/deep",
        "echo secret > /srv/tree/sub/private.txt",
        "chown alice:users /srv/tree/sub/private.txt",
        "chmod 600 /srv/tree/sub/private.txt",
        "chown alice:users /srv/tree/sub/deep",
        "chmod 750 /srv/tree/sub/deep",
        "echo run > /srv/tree/tool",
        "chmod 4755 /srv/tree/tool",
        "ln -s sub/private.txt /srv/tree/link",
        "chown -h alice:users /srv/tree/link",
    )

    # A missing path must not fail the unit.
    machine.succeed("systemctl start idrive-permission-manifest.service")
    machine.succeed("systemctl list-timers | grep -q idrive-permission-manifest")
    assert machine.succeed("stat -c %a /srv/tree/.idrive-perms.acl").strip() == "600"
    assert machine.succeed("stat -c %a /srv/tree/.idrive-links").strip() == "600"

    # Owned by whoever has to read it for the backup.
    machine.succeed(
        "mkdir /srv/other",
        "idrive-save-permissions --owner alice:users /srv/other",
    )
    assert machine.succeed("stat -c %U /srv/other/.idrive-perms.acl").strip() == "alice"


    def restored(path):
        machine.succeed(
            f"rm -rf {path}",
            f"mkdir -p {path}",
            f"cp -r --no-preserve=all /srv/tree/. {path}/",
            f"rm -f {path}/link",
            f"chown -R root:root {path}",
            f"chmod -R 777 {path}",
        )


    def mode(path):
        return machine.succeed(f"stat -c '%a %U:%G' {path}").strip()


    # A world-reachable location is refused, and nothing is touched.
    restored("/srv/staging/tree")
    machine.fail("idrive-restore-permissions /srv/staging/tree")
    assert mode("/srv/staging/tree/sub/private.txt") == "777 root:root"

    # Nor can a user run it.
    machine.fail("su alice -s /bin/sh -c 'idrive-restore-permissions /srv/staging/tree'")

    # A closed directory is no help if a user can replace it.
    restored("/srv/open/closed/tree")
    machine.succeed("chmod 777 /srv/open", "chmod 700 /srv/open/closed")
    machine.fail("idrive-restore-permissions /srv/open/closed/tree")
    assert mode("/srv/open/closed/tree/sub/private.txt") == "777 root:root"

    # The default restore location, with the modes the client really leaves:
    # world writable from user_profile down, under the 0700 state directory.
    R = "/var/lib/idrive/user_profile/root/account/Restore_Data/tree"
    restored(R)
    machine.succeed("chmod 777 /var/lib/idrive/user_profile/root/account/Restore_Data")
    machine.succeed("chmod 777 /var/lib/idrive/user_profile/root/account")
    machine.succeed(f"idrive-restore-permissions {R}")
    assert mode(f"{R}/sub/private.txt") == "600 alice:users"
    assert mode(f"{R}/sub/deep") == "750 alice:users"
    assert machine.succeed(f"readlink {R}/link").strip() == "sub/private.txt"
    assert machine.succeed(f"stat -c %U {R}/link").strip() == "alice"
    # The record's own mode, since a restored one starts at 0777.
    assert mode(f"{R}/.idrive-perms.acl").startswith("600")
    # setuid is left out by default.
    assert mode(f"{R}/tool") == "755 root:root"

    restored(R)
    machine.succeed(f"idrive-restore-permissions --keep-special {R}")
    assert mode(f"{R}/tool") == "4755 root:root"

    # A file newer than the manifest is still 0777, which has to be loud.
    restored(R)
    machine.succeed(f"touch {R}/newer && chmod 777 {R}/newer")
    out = machine.fail(f"idrive-restore-permissions {R} 2>&1")
    assert "newer" in out, out

    # --force gets past the location check.
    machine.succeed("idrive-restore-permissions --force /srv/staging/tree")
    assert mode("/srv/staging/tree/sub/private.txt") == "600 alice:users"

    # A record that reaches outside its tree is refused even with --force.
    machine.succeed("touch /srv/victim && chmod 600 /srv/victim")
    headers = [
        "# file: ../victim",
        "# file: ../../victim",
        "# file: /srv/victim",
        "# file: ./a/../../../victim",
        "# file: \\\\056\\\\056/\\\\056\\\\056/\\\\056\\\\056/\\\\056\\\\056/victim",
        "#file: ../../../../victim",
        "  # file: ../../../../victim",
    ]
    for header in headers:
        restored(R)
        # At the top, so a check that stops reading early would still see it,
        # and a check that skipped it would apply it.
        machine.succeed(
            f"printf '{header}\\n# owner: alice\\n# group: users\\n"
            f"user::rwx\\ngroup::rwx\\nother::rwx\\n\\n' > /tmp/evil",
            f"cat /tmp/evil {R}/.idrive-perms.acl > /tmp/evil2",
            f"cp /tmp/evil2 {R}/.idrive-perms.acl",
        )
        machine.fail(f"idrive-restore-permissions --force {R}")
        assert mode("/srv/victim") == "600 root:root", header

    # The same for the link list.
    restored(R)
    machine.succeed(f"printf '../../../../planted\\0/etc/shadow\\0root:root\\0' > {R}/.idrive-links")
    machine.fail(f"idrive-restore-permissions --force {R}")
    machine.fail("test -L /srv/planted || test -L /planted || test -L /var/planted")

    # A file name with a space and an ordinary dot must still work.
    machine.succeed(
        "touch '/srv/tree/a b.txt' && chmod 640 '/srv/tree/a b.txt'",
        "systemctl start idrive-permission-manifest.service",
    )
    restored(R)
    machine.succeed(f"idrive-restore-permissions {R}")
    assert machine.succeed(f"stat -c %a '{R}/a b.txt'").strip() == "640"
  '';
}
