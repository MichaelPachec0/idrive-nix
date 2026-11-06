{ pkgs, nixosModule, idrive-client }:

# restrictRoot leaves the client at uid 0, so the sandbox is all that stands
# between it and full root. Each probe runs under the exact properties of the
# real unit, and each is a way uid 0 gets out without any capability.
pkgs.testers.runNixOSTest {
  name = "idrive-restricted-root";

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ nixosModule ];
    virtualisation.diskSize = 4096;
    users.users.alice = { isNormalUser = true; };

    systemd.tmpfiles.rules = [
      "d /srv/data 0700 alice users -"
      "f /srv/data/private 0600 alice users - alice-only"
    ];

    services.idrive = {
      enable = true;
      acceptTerms = true;
      package = idrive-client;
      backupPaths = [ "/srv/data" ];
      scheduledBackup.enable = true;
      timeZone = "Etc/UTC";
    };

    systemd.services.bystander.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep 9999";
    systemd.services.bystander2.serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/touch /run/bystander2-ran";
    };

    systemd.services.probe = {
      path = with pkgs; [ coreutils util-linux systemd perl python3 ];
      serviceConfig = (lib.filterAttrs
        (name: _: !lib.elem name [ "ExecStart" "ExecStartPre" "Type" "Restart" "RestartSec" "StateDirectory" "StateDirectoryMode" ])
        config.systemd.services.idrive.serviceConfig) // { Type = "oneshot"; };
      script = ''
        t() { n=$1; shift; if "$@" >/dev/null 2>&1; then echo "ALLOWED $n"; else echo "blocked $n"; fi; }
        echo "uid $(id -u)"
        t read-other-user cat /srv/data/private
        t perl-r perl -e 'exit(-r $ARGV[0] ? 0 : 1)' /srv/data/private
        t shadow-has-content test -s /etc/shadow
        t write-statedir touch /var/lib/idrive/probe
        t write-data sh -c 'echo x >> /srv/data/private'
        t write-etc touch /etc/probe
        t write-root-home touch /root/probe
        t write-home touch /home/alice/probe
        t chown chown alice /var/lib/idrive/probe
        t sysctl sh -c 'echo probe > /proc/sys/kernel/hostname'
        t sysrq sh -c 'echo h > /proc/sysrq-trigger'
        t raw-disk sh -c 'dd if=/dev/vda of=/dev/null bs=512 count=1'
        t sysfs sh -c 'echo 1 > /sys/kernel/mm/ksm/run'
        t systemd-socket python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.connect("/run/systemd/private")'
        t dbus-socket python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.connect("/run/dbus/system_bus_socket")'
        t systemctl systemctl start bystander2.service
        t signal kill -0 "$(cat /run/bystander.pid)"
        t mount mount -t tmpfs none /mnt
        t userns unshare -U true
        t mknod mknod /var/lib/idrive/node b 8 0
        t setuid sh -c 'touch /var/lib/idrive/s && chmod 4755 /var/lib/idrive/s'
      '';
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # The daemon has to survive all of it, or none of this is usable.
    machine.wait_for_unit("idrive.service")
    machine.succeed("systemctl is-active idrive.service")

    # Baseline, so a probe marked blocked below means the sandbox did it. Root
    # outside the sandbox can do each of these.
    machine.succeed("test -s /etc/shadow")
    machine.succeed("test -e /dev/vda")

    machine.succeed("systemctl start bystander.service")
    machine.succeed("systemctl show bystander -p MainPID --value > /run/bystander.pid")
    machine.succeed("kill -0 $(cat /run/bystander.pid)")
    machine.succeed("systemctl start probe.service")
    out = machine.succeed("journalctl -u probe -b --no-pager -o cat")
    print(out)

    assert "uid 0\n" in out, out
    for probe in ["read-other-user", "perl-r", "write-statedir"]:
        assert f"ALLOWED {probe}\n" in out, f"{probe} should work: {out}"
    for probe in [
        "shadow-has-content", "write-data", "write-etc", "write-root-home",
        "write-home", "chown", "sysctl", "sysrq", "raw-disk", "sysfs",
        "systemd-socket", "dbus-socket", "systemctl", "signal", "mount",
        "userns", "mknod", "setuid",
    ]:
        assert f"blocked {probe}\n" in out, f"{probe} escaped the sandbox: {out}"
    machine.fail("test -e /run/bystander2-ran")
    machine.succeed("grep -qx alice-only /srv/data/private")

    # The same limits reach the client by hand and the backup unit.
    machine.succeed("command -v idrive-restricted")
    machine.succeed(
        "systemctl show idrive-backup.service -p CapabilityBoundingSet --value"
        " | grep -qx cap_dac_read_search"
    )
  '';
}
