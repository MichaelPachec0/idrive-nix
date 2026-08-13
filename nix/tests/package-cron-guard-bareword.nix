{ runCommand, coreutils, idrive-client }:

runCommand "idrive-cron-symlink-guard-bareword" { } ''
  set -eu
  # Regression test for the bare-word arm added to nix/wrappers.nix's argv0
  # resolution (the third case in `case "$0" in ... esac`). The existing
  # nix/tests/package-cron-guard.nix only exercises invoking the wrapper by
  # its absolute path; this one exercises the case that motivated the fix:
  # a caller that finds "idrive" purely via PATH and execs it as a bare
  # word with no slash at all (systemd's ExecStart when a package is only
  # on PATH, an OCI entrypoint doing `exec idrive --cron`, or an operator
  # typing "idrive --cron" at a shell with the package on PATH). In that
  # case bash sets argv0 to the literal string "idrive", not a path; before
  # the fix, prepending $PWD to that fabricated a nonexistent
  # "$PWD/idrive", which is never a symlink, tripping the client's own
  # `unless(-l $0)` guard on --cron and producing the exact silent-death
  # failure mode this test is named for. The fix resolves that bare word
  # through PATH with `command -v`, landing on ${idrive-client}/bin/idrive,
  # which IS a symlink, same as the absolute-path case already covered.
  #
  # As with the existing cron-guard test, this cannot assert --cron
  # performs a backup (no linked account exists in this sandbox); it only
  # asserts the symlink guard specifically does not fire.
  status=0
  env -i PATH="${idrive-client}/bin:${coreutils}/bin" \
    "${coreutils}/bin/timeout" 10 idrive --cron > out.txt 2>&1 || status=$?
  # 0: client ran and exited on its own (expected without a linked account).
  # 124: timeout fired, meaning --cron kept running past the guard check
  # instead of refusing outright - also a pass for this specific assertion.
  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
    echo "idrive --cron (bare word, PATH-resolved) exited $status unexpectedly:"
    cat out.txt
    exit 1
  fi
  if grep -qi 'Launch the service using service manager' out.txt; then
    echo "idrive --cron (bare word, PATH-resolved) tripped the client's own symlink guard:"
    cat out.txt
    exit 1
  fi
  cp out.txt $out
''
