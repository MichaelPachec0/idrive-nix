{ runCommand, idrive-client }:

runCommand "idrive-package-runs" { } ''
  set -eu
  # No PATH, no LD_LIBRARY_PATH inherited from the caller. If the binary
  # only works because the ambient environment happened to be right, this
  # is where that shows up.
  env -i "${idrive-client}/bin/idrive" --version > version.txt 2>&1 || {
    echo "idrive --version failed:"; cat version.txt; exit 1;
  }
  grep -qE '[0-9]+\.[0-9]+\.[0-9]+' version.txt || {
    echo "no version string in output:"; cat version.txt; exit 1;
  }
  cp version.txt $out
''
