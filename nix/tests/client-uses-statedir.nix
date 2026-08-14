{ runCommand, idrive-client, callPackage }:

let
  stateDir = "/tmp/idrive-state-client";

  # The exact entry point the NixOS module puts on PATH and runs as its
  # ExecStart, and that the image resolves "idrive" to. Running the real
  # launcher, not a hand-built approximation of it, is the point: this test
  # exists because every other state assertion in this suite checks files
  # the prepare script itself wrote, which is how a client that never used
  # stateDir at all coexisted with a green suite.
  launcher = (callPackage ../start.nix { inherit idrive-client; }).mkLauncher {
    inherit stateDir;
    timeZone = "Etc/UTC";
  };
in
runCommand "idrive-client-uses-statedir" { } ''
  set -eu
  export HOME=$TMPDIR
  rm -rf ${stateDir}

  # --account-setting is the documented first-run command. It needs no
  # credentials to get as far as its own authentication menu, and it is the
  # command that used to die with "Cannot open directory <store path>
  # Permission denied" because the client resolved its application
  # directory into the read-only store. Feeding it /dev/null makes it
  # exhaust its input attempts and exit on its own.
  status=0
  timeout 300 "${launcher}/bin/idrive" --account-setting \
    < /dev/null > setup.txt 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    echo "idrive --account-setting exited $status:"; cat setup.txt; exit 1
  fi
  if grep -qi 'permission denied' setup.txt; then
    echo "idrive --account-setting hit a permission error:"; cat setup.txt
    exit 1
  fi
  if ! grep -q 'Login using IDrive credentials' setup.txt; then
    echo "idrive --account-setting never reached its login prompt:"
    cat setup.txt
    exit 1
  fi

  # The assertion that only the client can satisfy. Every path under
  # user_profile/ is created by the client itself; the prepare script
  # writes idevsutil*, idrivecrontab.json, the version stamp and the
  # application directory, and nothing else. If the client were still
  # resolving its service path to the store, to the process cwd, or
  # anywhere else, this tree would simply not exist here.
  trace=$(find ${stateDir}/user_profile -name traceLog.txt 2>/dev/null | head -n1)
  if [ -z "$trace" ]; then
    echo "the client wrote no trace log under ${stateDir}/user_profile:"
    find ${stateDir} | sort
    exit 1
  fi

  # getBinaryPath() is "<appPath>/idrive", the path the client's own
  # scheduleAutoUpdateCRON, doDirectAppUpdate and isUpdateAvailable build
  # their self-invocations from. Now that appPath is this writable
  # directory, that file has to be a real-file copy of the update-blocking
  # wrapper - not a symlink (abs_path would resolve it back into the store
  # and reintroduce the bug) and not the unwrapped binary.
  if [ -L "${stateDir}/.app/idrive" ]; then
    echo "the application directory's idrive is a symlink; abs_path would"
    echo "resolve it back into the store"
    exit 1
  fi
  status=0
  "${stateDir}/.app/idrive" --check-update > upd.txt 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    echo "the client's own binary path did not refuse to self-update:"
    cat upd.txt
    exit 1
  fi

  # The daemon shape the module actually runs: the launcher routes --cron
  # through the idrivecron symlink, because the client refuses that mode
  # unless $0 names a symlink. Exit 0 (no linked account) and 124 (still
  # running past the guard) are both fine; the refusal message is not.
  status=0
  timeout 20 "${launcher}/bin/idrive" --cron > cron.txt 2>&1 || status=$?
  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
    echo "idrive --cron exited $status unexpectedly:"; cat cron.txt; exit 1
  fi
  if grep -qi 'Launch the service using service manager' cron.txt; then
    echo "the launcher's --cron path tripped the client's symlink guard:"
    cat cron.txt
    exit 1
  fi

  cp setup.txt $out
''
