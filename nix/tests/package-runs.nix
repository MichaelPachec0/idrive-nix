{ runCommand, idrive-client }:

runCommand "idrive-package-runs" { } ''
  set -eu
  # No PATH, no LD_LIBRARY_PATH inherited from the caller. If the binary
  # only works because the ambient environment happened to be right, this
  # is where that shows up.
  #
  # Streams are captured separately and the version assertion is checked
  # only against stdout, anchored to a whole line. idrive --version prints
  # its version to stdout with nothing else on that stream; Perl warnings
  # land on stderr. An unanchored grep over combined output would pass on a
  # stray dotted number in a warning even if --version stopped printing a
  # real version, so it is not used.
  #
  # warnings.txt still carries one expected line here:
  # `Use of uninitialized value $ENV{"HOME"} ...`. That one is env -i's own
  # doing (it deliberately strips HOME) and is not a missing-PATH-command
  # problem the wrapper could fix, unlike the uname/hostname/whoami
  # Can't-exec warnings the wrapper's PATH now eliminates. Left visible on
  # purpose rather than fabricating a HOME value to silence it.
  env -i "${idrive-client}/bin/idrive" --version > version.txt 2> warnings.txt || {
    echo "idrive --version failed:"; cat version.txt warnings.txt; exit 1;
  }
  grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' version.txt || {
    echo "no version line on stdout:"; cat version.txt warnings.txt; exit 1;
  }
  cp version.txt $out
''
