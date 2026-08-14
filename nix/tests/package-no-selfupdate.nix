{ runCommand, idrive-client }:

runCommand "idrive-no-selfupdate" { } ''
  set -eu
  # The self-updater rewrites the install tree in place and migrates the user
  # profile schema. Under Nix the tree is read-only, and a half-applied
  # migration is exactly the corruption reported upstream, so the entrypoint
  # must refuse rather than partially succeed.
  root="${idrive-client}/opt/IDriveForLinux"

  check_refused() {
    desc="$1"; shift
    if env -i "$@" > out.txt 2>&1; then
      echo "$desc succeeded; it must refuse under Nix"; cat out.txt; exit 1
    fi
    grep -qi 'managed by nix' out.txt || {
      echo "$desc: refusal message missing or unclear:"; cat out.txt; exit 1;
    }
  }

  # Every ARGV[0] token the wrapper's case statement blocks, invoked at the
  # public $out/bin/idrive entrypoint. Looped rather than tested once, so a
  # case-statement typo on any one of them ships green instead of silently
  # leaving that alias reachable. -C is the binary's own short alias for
  # --check-update (translated by its %shorttocmd table before dispatch).
  for flag in --check-update --handle-update --launch-update -C; do
    check_refused "idrive $flag" "${idrive-client}/bin/idrive" "$flag"
  done

  # A fourth, positional entry point: the dashboard spawns
  # "<binary> --utilities UPDATEFROMDASHBOARD dashboard &", which is not a
  # single ARGV[0] token and needs its own check.
  check_refused "idrive --utilities UPDATEFROMDASHBOARD" \
    "${idrive-client}/bin/idrive" --utilities UPDATEFROMDASHBOARD dashboard

  # Self-invocation. The client resolves its own path from $0
  # (loadAppPath -> getAbsPath($0) -> dirname), and scheduleAutoUpdateCRON,
  # doDirectAppUpdate, and isUpdateAvailable all build self-invocation
  # update commands from that resolved path - $root/bin/idrive - not from
  # $out/bin or argv. scheduleAutoUpdateCRON's crontab line in particular
  # runs unattended, with nobody watching for a refusal message. Invoking
  # that exact path directly, the way those call sites would, is the
  # assertion that proves the wrapper occupies it rather than the real,
  # unwrapped binary sitting there reachable.
  check_refused "self-invocation $root/bin/idrive --launch-update" \
    "$root/bin/idrive" --launch-update silent

  cp out.txt $out
''
