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
      # backup daemon) defaults to "idrive --cron"; an explicit override
      # (e.g. `idrive --version` for interactive diagnostics, as podman
      # passes it: CMD's own first token is already the program name, not
      # just its arguments) is used as-is. Either way "idrive" resolves
      # through PATH (runtimeInputs above), not a hardcoded absolute path:
      # nix/wrappers.nix's argv0 resolution has a bare-word arm that runs
      # `command -v` on a slash-less $0 and lands on
      # ${idrive-client}/bin/idrive, which IS a symlink, satisfying the
      # client's own `unless(-l $0)` guard on --cron. That fix lives once,
      # in the wrapper, rather than duplicated as an absolute-path
      # workaround at every call site that might invoke --cron (this
      # entrypoint, the NixOS module's ExecStart, or an interactive shell) -
      # see nix/tests/package-cron-guard-bareword.nix for the regression
      # test. set -- (not a plain default in the exec line) is deliberate:
      # "$@" must become exactly ("idrive" "--cron"), the same shape podman
      # would hand us for an explicit override, not "idrive" plus a
      # separately-quoted "--cron" tacked onto whatever "$@" already was.
      if [ "$#" -eq 0 ]; then
        set -- idrive --cron
      fi
      exec "$@"
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
