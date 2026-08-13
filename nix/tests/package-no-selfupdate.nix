{ runCommand, idrive-client }:

runCommand "idrive-no-selfupdate" { } ''
  set -eu
  # The self-updater rewrites the install tree in place and migrates the user
  # profile schema. Under Nix the tree is read-only, and a half-applied
  # migration is exactly the corruption reported upstream, so the entrypoint
  # must refuse rather than partially succeed.
  if env -i "${idrive-client}/bin/idrive" --check-update > out.txt 2>&1; then
    echo "--check-update succeeded; it must refuse under Nix"; cat out.txt; exit 1
  fi
  grep -qi 'managed by nix' out.txt || {
    echo "refusal message missing or unclear:"; cat out.txt; exit 1;
  }
  cp out.txt $out
''
