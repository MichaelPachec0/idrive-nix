{ runCommand, idrive-client }:

runCommand "idrive-package-runs" { } ''
  set -eu
  # No PATH, no LD_LIBRARY_PATH inherited from the caller. If the binary
  # only works because the ambient environment happened to be right, this
  # is where that shows up.
  #
  # Streams are captured separately and the version assertion is checked
  # only against stdout, anchored to a whole line. idrive --version prints
  # its version to stdout with nothing else on that stream; the Perl
  # warnings from AppConfig's uname/hostname/whoami probes (expected here,
  # since env -i leaves no PATH for those commands - that gap belongs to a
  # later wrapper task, not this one) land on stderr. An unanchored grep
  # over combined output would pass on a stray dotted number in a warning
  # even if --version stopped printing a real version, so it is not used.
  env -i "${idrive-client}/bin/idrive" --version > version.txt 2> warnings.txt || {
    echo "idrive --version failed:"; cat version.txt warnings.txt; exit 1;
  }
  grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' version.txt || {
    echo "no version line on stdout:"; cat version.txt warnings.txt; exit 1;
  }
  cp version.txt $out
''
