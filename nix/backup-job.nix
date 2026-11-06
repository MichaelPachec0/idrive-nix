{ lib, runtimeShell, writeShellApplication, writeShellScriptBin, writeText, coreutils, gnugrep, perl, util-linux }:

# One backup run for a systemd timer. The client's exit code says nothing: it
# is 0 for a failed job, for no stored login, and for a run that skipped files
# it could not read. So the verdict comes from the log the run leaves behind.
#
# paths is the backup set. Nix owns it, so it replaces whatever the client holds
# when either side changed. settleSeconds is the wait after pushing a set, while
# the client rescans.
{ client, stateDir, paths, settleSeconds ? 15 }:
let
  setFile = writeText "idrive-backup-set" (lib.concatLines paths);

  # --edit-job-sets opens the set in an editor. This one writes the wanted set
  # and exits. The client's messages are keyed by editor name, hence nano.
  editor = writeShellScriptBin "nano" ''
    for target; do :; done
    ${coreutils}/bin/cat ${setFile} > "$target"
  '';

  # The client walks the set in Perl and drops what `-r` rejects. A file gets one
  # [INFORMATION] line and a directory gets none, and the job still says Success.
  # This repeats the same test, because `-r` reads the mode bits and ignores
  # ACLs, so `test -r` or find -readable would disagree with the client.
  checkReadable = writeText "idrive-check-readable.pl" ''
    use strict;
    use File::Find;
    my $bad = 0;
    sub report { $bad++; print "$_[0]\n" if $bad <= 50; }
    my @roots;
    for my $path (@ARGV) {
      if (-e $path) { push @roots, $path; } else { report("missing: $path"); }
    }
    find({ no_chdir => 1, wanted => sub {
      my $path = $File::Find::name;
      return if -l $path;
      if (-d $path) {
        return if -r $path && -x $path;
        $File::Find::prune = 1;
      } elsif (-r $path) {
        return;
      }
      report("unreadable: $path");
    } }, @roots) if @roots;
    print "$bad path(s) will not be backed up\n" if $bad;
    exit($bad ? 1 : 0);
  '';
in
writeShellApplication {
  name = "idrive-backup-job";
  runtimeInputs = [ coreutils gnugrep perl util-linux ];
  # The log names have no spaces, and ls -t is the simplest newest-first.
  excludeShellChecks = [ "SC2012" ];
  text = ''
    state=${lib.escapeShellArg stateDir}
    client=${lib.escapeShellArg client}
    settle=${toString settleSeconds}

    shopt -s nullglob
    configs=("$state/user_profile/$(id -un)"/*/CONFIGURATION_FILE)
    shopt -u nullglob
    if [ "''${#configs[@]}" -ne 1 ]; then
      echo "idrive-backup-job: expected one linked account, found ''${#configs[@]}" >&2
      exit 1
    fi
    job=$(dirname "''${configs[0]}")/Backup/DefaultBackupSet
    logs=$job/LOGS
    stamp=$state/.backup-set
    status=0

    newest() { ls -t "$logs" 2>/dev/null | head -n 1 || true; }
    fingerprint() {
      cat ${setFile} "$job/BackupsetFile.enc" 2>/dev/null | sha256sum | cut -d' ' -f1
    }

    # Returns 1 only when the job itself failed. Files it left out still count
    # as a run, and turn the unit red through status.
    run_once() {
      local before log rc=0 failed
      before=$(newest)
      "$client" --backup --silent </dev/null || rc=$?
      for _ in $(seq 1 30); do
        log=$(newest)
        case "$log" in
          *Running*) sleep 1 ;;
          *) break ;;
        esac
      done
      if [ -z "$log" ] || [ "$log" = "$before" ]; then
        echo "idrive-backup-job: no new log, the job did not run (client exit $rc)" >&2
        return 1
      fi
      case "$log" in
        *_Success_*) ;;
        *)
          echo "idrive-backup-job: client reported $log" >&2
          return 1
          ;;
      esac
      grep -E 'Files (considered|backed up now|failed)' "$logs/$log" || true
      failed=$(grep -oE 'Files failed to backup : [0-9]+' "$logs/$log" | grep -oE '[0-9]+$' || true)
      if [ "''${failed:-0}" != 0 ]; then
        status=1
      fi
      if grep -F '[INFORMATION]' "$logs/$log" | grep -F 'Reason'; then
        status=1
      fi
    }

    if ! perl ${checkReadable} ${lib.escapeShellArgs paths}; then
      status=1
    fi

    attempts=1
    if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$(fingerprint)" ]; then
      echo "idrive-backup-job: updating the backup set"
      # script runs its command through $SHELL, which is nologin for a system
      # user. The pty is there because the client wants a terminal.
      out=$(EDITOR=${editor}/bin/nano TERM=dumb SHELL=${runtimeShell} \
        script -qec "$client --edit-job-sets backup" /dev/null </dev/null || true)
      if ! grep -q 'Backupset is updated' <<< "$out"; then
        echo "idrive-backup-job: the client did not accept the backup set" >&2
        tail -n 5 <<< "$out" >&2
        exit 1
      fi
      fingerprint > "$stamp.tmp"
      mv "$stamp.tmp" "$stamp"
      sleep "$settle"
      # The first backup after a set change has failed for no visible reason,
      # and passed when run again.
      attempts=2
    fi

    until run_once; do
      attempts=$((attempts - 1))
      if [ "$attempts" -le 0 ]; then
        exit 1
      fi
      sleep "$settle"
    done
    exit "$status"
  '';
}
