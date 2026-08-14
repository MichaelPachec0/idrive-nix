{ runCommand, idrive-client, callPackage }:

let
  prepare = (callPackage ../start.nix { inherit idrive-client; }).mkPrepare {
    stateDir = "/tmp/idrive-state-bad-timezone";
    timeZone = "Not/AZone";
  };
in
runCommand "idrive-prepare-bad-timezone" { } ''
  set -eu
  export HOME=$TMPDIR
  rm -rf /tmp/idrive-state-bad-timezone

  # A nonexistent zoneinfo entry must fail the script loudly, not fall
  # through to a silent UTC default.
  if "${prepare}/bin/idrive-prepare" 2>err.log; then
    echo "idrive-prepare unexpectedly succeeded with an invalid timezone"
    exit 1
  fi

  grep -q "Not/AZone" err.log || {
    echo "error message did not name the bad timezone value"
    cat err.log
    exit 1
  }

  echo ok > $out
''
