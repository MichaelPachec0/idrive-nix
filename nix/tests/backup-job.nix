{ pkgs }:

# The job's verdict, against a stub client that writes the logs the real one
# does. The behaviours below were each seen from the real client: exit 0 from a
# failed job, exit 0 with no log at all, and Success with files left out.
let
  stub = pkgs.writeShellScript "stub-client" ''
    job=$STUB_STATE/user_profile/$(id -un)/acct/Backup/DefaultBackupSet
    case "$1" in
      --edit-job-sets)
        echo edit >> "$STUB_STATE/calls"
        "$EDITOR" "$job/BackupsetFile.enc"
        [ -f "$STUB_STATE/reject-set" ] || echo "Backupset is updated."
        exit 0
        ;;
    esac
    echo backup >> "$STUB_STATE/calls"
    n=$(wc -l < "$STUB_STATE/calls")
    mode=$(sed -n 1p "$STUB_STATE/modes")
    sed -i 1d "$STUB_STATE/modes"
    log=$job/LOGS/$((1700000000 + n))
    case "$mode" in
      nolog) ;;
      failure) echo "Files failed to backup : 0" > "''${log}_Failure_Manual" ;;
      failed-files) echo "Files failed to backup : 3" > "''${log}_Success_Manual" ;;
      denied) printf 'Files failed to backup : 0\n[now] [INFORMATION] [/x]. Reason: Permission denied\n' > "''${log}_Success_Manual" ;;
      *) printf 'Files considered for backup : 1\nFiles failed to backup : 0\n' > "''${log}_Success_Manual" ;;
    esac
    exit 0
  '';

  job = pkgs.callPackage ../backup-job.nix { } {
    client = "${stub}";
    stateDir = "/tmp/idrive-job-test";
    paths = [ "/tmp/idrive-job-data" ];
    settleSeconds = 0;
  };
in
pkgs.runCommand "idrive-backup-job-test" { } ''
  export STUB_STATE=/tmp/idrive-job-test
  # What a system user has. script would otherwise run the client through it.
  export SHELL=/bin/false
  data=/tmp/idrive-job-data

  reset() {
    chmod -R u+rwx "$data" 2>/dev/null || true
    rm -rf "$STUB_STATE" "$data"
    mkdir -p "$STUB_STATE/user_profile/$(id -un)/acct/Backup/DefaultBackupSet/LOGS" "$data/sub"
    touch "$STUB_STATE/user_profile/$(id -un)/acct/CONFIGURATION_FILE" "$STUB_STATE/calls" "$data/sub/ok"
    printf '%s\n' "$@" > "$STUB_STATE/modes"
  }
  expect() {
    want=$1; name=$2; rc=0
    ${job}/bin/idrive-backup-job > out 2>&1 || rc=$?
    if [ "$rc" != "$want" ]; then
      echo "FAIL $name: exit $rc, wanted $want"; cat out; exit 1
    fi
    echo "ok $name"
  }

  reset ok ok
  expect 0 "clean run"
  grep -qx /tmp/idrive-job-data "$STUB_STATE/user_profile/$(id -un)/acct/Backup/DefaultBackupSet/BackupsetFile.enc"
  [ "$(grep -c edit "$STUB_STATE/calls")" = 1 ]
  expect 0 "second run"
  [ "$(grep -c edit "$STUB_STATE/calls")" = 1 ] || { echo "FAIL set pushed again with no change"; exit 1; }

  echo changed > "$STUB_STATE/user_profile/$(id -un)/acct/Backup/DefaultBackupSet/BackupsetFile.enc"
  echo ok >> "$STUB_STATE/modes"
  expect 0 "set edited outside Nix"
  [ "$(grep -c edit "$STUB_STATE/calls")" = 2 ] || { echo "FAIL Nix did not win"; exit 1; }
  grep -qx /tmp/idrive-job-data "$STUB_STATE/user_profile/$(id -un)/acct/Backup/DefaultBackupSet/BackupsetFile.enc"

  reset failure ok
  expect 0 "failure right after a set change is retried"

  reset ok failure failure
  expect 0 "first run"
  expect 1 "failure with an unchanged set is not retried"
  [ "$(grep -c backup "$STUB_STATE/calls")" = 2 ]

  reset failure failure
  expect 1 "failure twice"

  reset nolog nolog
  expect 1 "no log"
  grep -q 'did not run' out

  reset failed-files
  expect 1 "failed files under Success"

  reset denied
  expect 1 "permission denied under Success"
  grep -q 'Permission denied' out

  reset ok
  touch "$STUB_STATE/reject-set"
  expect 1 "set rejected"
  [ "$(grep -c backup "$STUB_STATE/calls")" = 0 ] || { echo "FAIL ran with a rejected set"; exit 1; }

  reset ok
  rm "$STUB_STATE/user_profile/$(id -un)/acct/CONFIGURATION_FILE"
  expect 1 "no linked account"

  reset ok
  touch "$data/sub/locked"; chmod 000 "$data/sub/locked"
  expect 1 "unreadable file"
  grep -q 'unreadable: /tmp/idrive-job-data/sub/locked' out
  [ "$(grep -c backup "$STUB_STATE/calls")" = 1 ] || { echo "FAIL readable files were not backed up"; exit 1; }

  reset ok
  mkdir "$data/closed"; touch "$data/closed/hidden"; chmod 700 "$data/closed"; chmod 000 "$data/closed"
  expect 1 "unreadable directory"
  grep -q 'unreadable: /tmp/idrive-job-data/closed' out

  reset ok
  chmod -R u+rwx "$data"; rm -rf "$data"
  expect 1 "missing path"
  grep -q 'missing: /tmp/idrive-job-data' out
  mkdir -p "$data"

  touch $out
''
