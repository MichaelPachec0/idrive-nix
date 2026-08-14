{ runCommand, idrive-client }:

runCommand "idrive-cron-symlink-guard" { } ''
  set -eu
  # The client's own --cron entry point refuses immediately with this exact
  # message unless $0 names a filesystem symlink at the moment the real
  # binary is exec'd: "unless(-l $0){...saferetreat(
  # 'you_cant_run_supporting_service')}", extracted directly from the
  # binary. This is a regression guard for nix/wrappers.nix's
  # `exec -a "$0"`: a hardcoded, non-symlink $0 (the bug this replaced)
  # trips this guard on every entry point the package exposes, making
  # --cron permanently unusable regardless of NixOS/systemd configuration.
  #
  # This cannot assert that --cron actually performs a backup; that needs a
  # linked IDrive account, which does not exist in this sandbox. It only
  # asserts the client's symlink guard does not fire, which is the specific
  # failure mode the wrapper fix addresses and the only part of --cron's
  # behavior observable without live credentials.
  status=0
  timeout 10 env -i "${idrive-client}/bin/idrive" --cron > out.txt 2>&1 || status=$?
  # 0: client ran and exited on its own (expected without a linked account).
  # 124: timeout fired, meaning --cron kept running past the guard check
  # instead of refusing outright - also a pass for this specific assertion.
  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
    echo "idrive --cron exited $status unexpectedly:"; cat out.txt; exit 1
  fi
  if grep -qi 'Launch the service using service manager' out.txt; then
    echo "idrive --cron tripped the client's own symlink guard:"
    cat out.txt
    exit 1
  fi
  cp out.txt $out
''
