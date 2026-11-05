{ runCommand, idrive-client, callPackage }:

let
  prepare = (callPackage ../start.nix { inherit idrive-client; }).mkPrepare {
    stateDir = "/tmp/idrive-state";
    timeZone = "Etc/UTC";
  };
in
runCommand "idrive-prepare-script" { } ''
  set -eu
  export HOME=$TMPDIR
  rm -rf /tmp/idrive-state

  "${prepare}/bin/idrive-prepare"
  test -d /tmp/idrive-state || { echo "state dir not created"; exit 1; }
  test -f /tmp/idrive-state/idrivecrontab.json || { echo "crontab json not created"; exit 1; }
  test -f /tmp/idrive-state/.idrive-version || { echo "version stamp missing"; exit 1; }

  # Running twice must not clobber user state. This is the property the old
  # idriveIt.orig copy-back hack got wrong for bind-mount users.
  echo "USERDATA" > /tmp/idrive-state/user_profile_marker
  "${prepare}/bin/idrive-prepare"
  grep -q USERDATA /tmp/idrive-state/user_profile_marker || {
    echo "second run clobbered user state"; exit 1;
  }

  # A stale recorded version makes the client refuse every job, so prepare
  # has to fix it, but must not invent one for an account never set up.
  test ! -e /tmp/idrive-state/cache/version || { echo "invented cache/version"; exit 1; }
  mkdir -p /tmp/idrive-state/cache
  printf '0.0.0' > /tmp/idrive-state/cache/version
  "${prepare}/bin/idrive-prepare"
  [ "$(cat /tmp/idrive-state/cache/version)" = "${idrive-client.version}" ] || {
    echo "stale cache/version was left in place"; exit 1;
  }
  echo ok > $out
''
