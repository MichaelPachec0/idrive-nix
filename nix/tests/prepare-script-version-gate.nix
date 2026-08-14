{ runCommand, idrive-client, callPackage }:

let
  # Three idrive-client derivations, fake in exactly two dimensions: the
  # version string, and a build input that changes the store path without
  # changing anything else. This is deliberately not a different `src`:
  # what is under test is mkPrepare's staging gate - that it re-stages
  # exactly when the package it stages from changes - not whether two
  # different client releases produce different bytes. Using overrideAttrs
  # keeps the real package's pinned version (used everywhere else in the
  # flake) untouched; only these local values are fake.
  #
  # `probe` is an unknown derivation attribute, so it reaches the build as
  # an environment variable and nothing else: it moves the store path while
  # leaving pname, version and every byte of the result alone. That is what
  # makes clientV1b possible, and clientV1b is the whole point - a pair
  # differing only in store path is the only pair that can tell a
  # path-keyed gate from a version-keyed one, and it is the real-world
  # shape of the failure, since `nix flake update` moves the store path
  # while the client's own version stays put.
  mkFakeClient = { version, probe }: idrive-client.overrideAttrs (_: {
    inherit version;
    __intentionallyOverridingVersion = true;
    __gateProbe = probe;
  });

  clientV1 = mkFakeClient { version = "9.9.1-test"; probe = "a"; };
  clientV1b = mkFakeClient { version = "9.9.1-test"; probe = "b"; };
  clientV2 = mkFakeClient { version = "9.9.2-test"; probe = "a"; };

  mkPrepareFor = client: (callPackage ../start.nix { idrive-client = client; }).mkPrepare {
    stateDir = "/tmp/idrive-state-version-gate";
    timeZone = "Etc/UTC";
  };

  prepareV1 = mkPrepareFor clientV1;
  prepareV1b = mkPrepareFor clientV1b;
  prepareV2 = mkPrepareFor clientV2;
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

  # Direction 3: the same version from a different store path MUST
  # re-sync. This is the one direction a version-keyed gate gets wrong, and
  # the one this whole check exists for: the staged copies carry RUNPATHs
  # into the store, so once the store path moves they are stale, and after
  # the next `nix-collect-garbage -d` they reference deleted libraries. A
  # gate that compared versions would skip here and leave the corruption
  # (and, in the real failure, the stale binaries) in place.
  echo "CORRUPT-NEW-PATH" > "$synced"
  "${prepareV1b}/bin/idrive-prepare"
  if grep -q CORRUPT-NEW-PATH "$synced"; then
    echo "same-version, different-path run did not re-sync; the gate is"
    echo "keyed on the version string again"
    exit 1
  fi
  test "$(cat /tmp/idrive-state-version-gate/.idrive-version)" = "9.9.1-test" || {
    echo "version stamp changed on a same-version run"; exit 1;
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
