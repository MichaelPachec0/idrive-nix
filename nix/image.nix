{ lib
, dockerTools
, writeShellApplication
, bashInteractive
, coreutils
, cacert
, tzdata
, callPackage
, idrive-client
, timeZone ? "Etc/UTC"
}:

let
  stateDir = "/opt/IDriveForLinux/idriveIt";

  startLib = callPackage ./start.nix { inherit idrive-client; };

  # The same launcher the native systemd unit uses as its ExecStart: it
  # prepares the state directory (including the writable application
  # directory the client resolves its own appPath to) and execs the client
  # through it. Sharing it is what stops the two backends from drifting.
  # It is listed ahead of idrive-client in runtimeInputs below so a bare
  # "idrive" resolves to it and not to the package's own bin/idrive, whose
  # appPath would be the read-only store.
  idrive = startLib.mkLauncher {
    inherit stateDir timeZone;
  };

  entrypoint = writeShellApplication {
    name = "idrive-entrypoint";
    runtimeInputs = [ idrive idrive-client ];
    text = ''
      set -euo pipefail

      # No command override (the container's real, intended use: run as the
      # backup daemon) defaults to "idrive --cron"; an explicit override
      # (e.g. `idrive --version` for interactive diagnostics, as podman
      # passes it: CMD's own first token is already the program name, not
      # just its arguments) is used as-is. Either way "idrive" is resolved
      # through PATH (runtimeInputs above) to the launcher, which runs the
      # prepare step and then routes --cron through the idrivecron symlink
      # in the writable application directory, satisfying the client's
      # `unless(-l $0)` guard (see nix/start.nix and nix/wrappers.nix).
      # set -- (not a plain default in the exec line) is deliberate: "$@"
      # must become exactly ("idrive" "--cron"), the same shape podman
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
  # Not "latest": loading successive builds under a fixed tag lets a
  # container backend keep running a stale image after the underlying
  # store path has changed, with no signal that anything is out of date.
  tag = idrive-client.version;

  # vim, nano, unzip, iputils-ping, iproute2 and cron are deliberately absent.
  # The client runs its own scheduler, and a backup agent has no business
  # shipping an editor.
  contents = [
    idrive-client
    bashInteractive
    coreutils
    cacert
    tzdata
    # Without a /etc/passwd entry for uid 0, any getpwuid(0) lookup fails -
    # observed directly as "whoami: cannot find name for user ID 0" in this
    # image's own container logs. The client's own startup calls whoami to
    # populate $AppConfig::mcUser, and leaves it uninitialized when that
    # lookup fails; mcUser in turn is used to build the user_profile/<user>
    # path the client reads its account state from. A missing or wrong
    # profile path is exactly the class of failure this whole packaging
    # effort exists to prevent, so this is not cosmetic. fakeNss supplies
    # /etc/passwd and /etc/group entries for root (and nobody); binSh gives
    # those entries' /bin/sh a real target instead of a dangling reference
    # (bashInteractive above already provides an interactive shell for
    # -it use; binSh only wires the passwd/group entries to it).
    dockerTools.fakeNss
    dockerTools.binSh
  ];

  config = {
    Entrypoint = [ "${entrypoint}/bin/idrive-entrypoint" ];
    Env = [
      # Not en_US.UTF-8: this image ships no locale data (the old Ubuntu
      # image installed locales-all; pulling in glibcLocales here just to
      # get one locale would bloat this image for a backup agent that does
      # not need it). C.UTF-8 is glibc's own built-in UTF-8 locale - no
      # locale-archive required - and stops every bash invocation in the
      # entrypoint from printing "setlocale: LC_ALL: cannot change locale
      # (en_US.UTF-8): No such file or directory".
      "LC_ALL=C.UTF-8"
      "TZ=${timeZone}"
      # dockerTools.buildLayeredImage symlinks tzdata's top-level share/
      # directory into the image root, giving /share/zoneinfo; glibc's own
      # timezone lookup instead checks /etc/localtime or, absent that,
      # /usr/share/zoneinfo, neither of which exists here. Without TZDIR
      # pointed at the actual zoneinfo location, TZ is silently ignored:
      # an operator setting -e TZ=Europe/Berlin gets backups stamped UTC
      # with no error, exactly the failure nix/start.nix's timezone
      # validation exists to prevent (that validation only confirms the
      # zoneinfo file exists at build/prepare time; it does not make the
      # running process able to find it without this).
      "TZDIR=${tzdata}/share/zoneinfo"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    Volumes = { "${stateDir}" = { }; };
    WorkingDir = "/opt/IDriveForLinux/bin";
  };
}
