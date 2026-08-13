{ lib
, dockerTools
, writeShellApplication
, bashInteractive
, coreutils
, cacert
, tzdata
, callPackage
, idrive-client
}:

let
  stateDir = "/opt/IDriveForLinux/idriveIt";

  startLib = callPackage ./start.nix { inherit idrive-client; };
  prepare = startLib.mkPrepare {
    inherit stateDir;
    timeZone = "Etc/UTC";
  };

  # The image runs the same prepare step the native systemd unit runs as
  # ExecStartPre. Sharing it is what stops the two backends from drifting.
  launcher = writeShellApplication {
    name = "idrive-entrypoint";
    runtimeInputs = [ idrive-client ];
    text = ''
      set -euo pipefail
      "${prepare}/bin/idrive-prepare"

      # No command override (the container's real, intended use: run as the
      # backup daemon) means run cron. Do that through the absolute symlink
      # path, not a bare `idrive` resolved via PATH: bash sets a bare word's
      # argv0 to the literal string "idrive", and the wrapper's own
      # symlink-guard workaround (nix/wrappers.nix, exec -a "$0") falls back
      # to "$PWD/idrive" for an argv0 with no slash in it, which does not
      # exist as a file at all, let alone a symlink. The client's --cron
      # entry point refuses to run unless $0 names a filesystem symlink, so
      # a bare PATH lookup here would trip that guard, print "Launch the
      # service using service manager.", and exit 0 immediately - a
      # container that starts and dies instantly with no useful signal.
      # ${idrive-client}/bin/idrive IS a symlink (see nix/wrappers.nix), so
      # this satisfies the guard exactly like the NixOS module's own
      # ExecStart.
      #
      # A command override (e.g. `idrive --version` for interactive
      # diagnostics) does not go through --cron and so does not need the
      # symlink guard; forward it via "$@" and let it resolve through PATH,
      # which runtimeInputs above already provides.
      if [ "$#" -eq 0 ]; then
        exec "${idrive-client}/bin/idrive" --cron
      else
        exec "$@"
      fi
    '';
  };
in
dockerTools.buildLayeredImage {
  name = "idrive-docker";
  tag = "latest";

  # vim, nano, unzip, iputils-ping, iproute2 and cron are deliberately absent.
  # The client runs its own scheduler, and a backup agent has no business
  # shipping an editor.
  contents = [
    idrive-client
    bashInteractive
    coreutils
    cacert
    tzdata
  ];

  config = {
    Entrypoint = [ "${launcher}/bin/idrive-entrypoint" ];
    Env = [
      "LC_ALL=en_US.UTF-8"
      "TZ=Etc/UTC"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    Volumes = { "${stateDir}" = { }; };
    WorkingDir = "/opt/IDriveForLinux/bin";
  };
}
