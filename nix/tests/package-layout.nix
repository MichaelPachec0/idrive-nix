{ runCommand, idrive-client }:

runCommand "idrive-package-layout" { } ''
  set -eu
  root="${idrive-client}/opt/IDriveForLinux"
  test -d "$root"            || { echo "missing $root"; exit 1; }
  test -d "$root/bin"        || { echo "missing $root/bin"; exit 1; }

  # The client itself ships inside a nested archive, not in the outer payload.
  test -x "$root/bin/idrive" || { echo "missing or non-executable idrive"; exit 1; }

  # Vendored Python 3.5 runtime and the dashboard binary.
  test -d "$root/bin/Idrivelib/dependencies/python/lib" \
    || { echo "vendored python not extracted"; exit 1; }
  test -x "$root/bin/Idrivelib/dependencies/python/dashboard" \
    || { echo "dashboard missing"; exit 1; }

  # Transfer tools, shipped where the prepare script expects to find them.
  ls "$root/idriveIt"/idevsutil* >/dev/null \
    || { echo "idevsutil binaries not extracted into idriveIt"; exit 1; }

  # The wrapper generation loop in postInstall silently produces zero
  # wrappers ('continue' on a missing source) if the idriveIt source path
  # is ever wrong, and every other check here would still pass. Assert the
  # public $out/bin/idevsutil wrapper actually exists so that failure mode
  # shows up.
  test -x "${idrive-client}/bin/idevsutil" \
    || { echo "missing or non-executable \$out/bin/idevsutil wrapper"; exit 1; }

  echo ok > $out
''
