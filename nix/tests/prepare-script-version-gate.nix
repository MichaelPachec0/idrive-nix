{ runCommand, idrive-client, callPackage }:

let
  # Two idrive-client derivations that differ only in `version`, which
  # makes them differ in store path too, since the store path's name is
  # built from pname and version. This is deliberately not a different
  # `src`: what is under test is mkPrepare's staging gate - that it
  # re-stages exactly when the package it stages from changes - not whether
  # two different client releases produce different bytes. Using
  # overrideAttrs keeps the real package's pinned version (used everywhere
  # else in the flake) untouched; only these two local values are fake.
  mkFakeVersion = version: idrive-client.overrideAttrs (_: {
    inherit version;
    __intentionallyOverridingVersion = true;
  });

  clientV1 = mkFakeVersion "9.9.1-test";
  clientV2 = mkFakeVersion "9.9.2-test";

  prepareV1 = (callPackage ../start.nix { idrive-client = clientV1; }).mkPrepare {
    stateDir = "/tmp/idrive-state-version-gate";
    timeZone = "Etc/UTC";
  };
  prepareV2 = (callPackage ../start.nix { idrive-client = clientV2; }).mkPrepare {
    stateDir = "/tmp/idrive-state-version-gate";
    timeZone = "Etc/UTC";
  };
in
runCommand "idrive-prepare-version-gate" { } ''
  set -eu
  export HOME=$TMPDIR
  rm -rf /tmp/idrive-state-version-gate

  synced="/tmp/idrive-state-version-gate/idevsutil"

  "${prepareV1}/bin/idrive-prepare"
  test "$(cat /tmp/idrive-state-version-gate/.idrive-version)" = "9.9.1-test" || {
    echo "stamp did not record the first version"; exit 1;
  }
  test -e "$synced" || { echo "idevsutil was not staged on first run"; exit 1; }

  # Direction 1: same version again must NOT re-sync. An always-true (or
  # inverted, or always-false-that-happens-to-match-once) gate would still
  # restore the staged file from the store here and wipe the corruption.
  echo "CORRUPT-SAME-VERSION" > "$synced"
  "${prepareV1}/bin/idrive-prepare"
  grep -q CORRUPT-SAME-VERSION "$synced" || {
    echo "same-version run re-synced when the gate should have skipped it"
    exit 1
  }
  test "$(cat /tmp/idrive-state-version-gate/.idrive-version)" = "9.9.1-test" || {
    echo "stamp changed on a same-version run"; exit 1;
  }

  # Direction 2: a changed version MUST re-sync, overwriting the corruption
  # left above, and advance the stamp. An always-false gate would leave the
  # corruption in place and never move the stamp past 9.9.1-test.
  "${prepareV2}/bin/idrive-prepare"
  if grep -q CORRUPT-SAME-VERSION "$synced"; then
    echo "version-changed run did not re-sync; corruption survived"
    exit 1
  fi
  test "$(cat /tmp/idrive-state-version-gate/.idrive-version)" = "9.9.2-test" || {
    echo "stamp did not advance to the new version"; exit 1;
  }

  echo ok > $out
''
