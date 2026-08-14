{ runCommand, shellcheck, idrive-client }:

# Every other shell script in this flake is produced by
# writeShellApplication, which runs shellcheck at build time. The
# update-blocking wrapper is the exception: nix/wrappers.nix writes it into
# the package's own bin/ during postInstall (it has to live there, at the
# path the client resolves for itself), so nothing lints it. This closes
# that gap. It passes today; it exists so an edit to that generated script
# cannot quietly introduce a quoting or expansion bug in the one script
# standing between the client and its self-updater.
runCommand "idrive-wrapper-shellcheck"
{
  nativeBuildInputs = [ shellcheck ];
} ''
  set -eu

  wrapper="${idrive-client}/opt/IDriveForLinux/bin/idrive"
  if [ -L "$wrapper" ]; then
    echo "$wrapper is a symlink; the wrapper must be the real file there" >&2
    exit 1
  fi

  shellcheck -s bash "$wrapper"

  # Guard against linting the wrong file: a package whose bin/idrive were
  # somehow not the wrapper would still be a valid bash script and still
  # pass shellcheck above.
  grep -q 'this build will not self-update' "$wrapper" || {
    echo "$wrapper is not the update-blocking wrapper" >&2
    exit 1
  }

  echo ok > $out
''
