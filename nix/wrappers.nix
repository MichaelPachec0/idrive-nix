# The argv-intercepting update-blocking wrapper and the idevsutil wrappers,
# shared between nix/package.nix (3.14.0, built from the vendor .bin) and
# nix/package-from-image.nix (3.8.0, extracted from the published image
# layer). Both packages need byte-identical wrapper behavior; duplicating
# this block in two derivations would let them drift, so it lives here once.
#
# mkWrappers { root, vendorLib } returns a shell fragment meant to run as (or
# be appended to) a derivation's postInstall. `root` and `vendorLib` are
# spliced into the generated shell text verbatim, so callers may pass either
# a literal store path or a shell-variable reference such as "$root" that is
# already set earlier in the same build script (both existing callers set
# root="$out/opt/IDriveForLinux" in their installPhase, and stdenv runs every
# phase in one shell, so the variable is still in scope in postInstall).
{ lib, bash, coreutils, gnutar, gzip, procps, util-linux, unixtools }:

{
  mkWrappers = { root, vendorLib }: ''
    # The update logic is compiled into the static bin/idrive binary and is
    # reachable only through these ARGV[0] tokens (checked below against the
    # real, not-yet-moved binary) plus the --utilities UPDATEFROMDASHBOARD
    # positional form. Assert every one of them still exists in the binary,
    # so an upstream rename fails the build rather than silently leaving the
    # wrapper matching a dead string while the updater stays reachable. This
    # check runs before the binary is moved aside, against the real payload.
    for token in \
      '--check-update' '--handle-update' '--launch-update' \
      "'-C'=>" '--utilities' 'UPDATEFROMDASHBOARD'
    do
      if ! grep -qa -- "$token" "${root}/bin/idrive"; then
        echo "the update-related token '$token' was not found in bin/idrive" >&2
        echo "upstream may have renamed it; re-run the phase 0 string analysis" >&2
        exit 1
      fi
    done

    mkdir -p "$out/bin"

    # Move the real binary aside and install the wrapper AT $root/bin/idrive
    # itself, rather than only at $out/bin/idrive. The client resolves its
    # own path from $0 (loadAppPath -> getAbsPath($0) -> dirname), and three
    # internal call sites build self-invocation update commands from that
    # resolved path: scheduleAutoUpdateCRON (writes a crontab line calling
    # "<binary> --launch-update silent", run unattended during setup),
    # doDirectAppUpdate (the dashboard's direct-update path), and
    # isUpdateAvailable (backgrounds a "--check-update checkUpdate" call).
    # If the real binary stayed at $root/bin/idrive, those self-invocations
    # would resolve straight to it and bypass a wrapper sitting only at
    # $out/bin. Occupying $root/bin/idrive with the wrapper closes that.
    mv "${root}/bin/idrive" "${root}/bin/.idrive-unwrapped"

    # Argv-intercepting wrapper. The client's in-place updater rewrites its
    # own install tree, which is read-only here, and migrates the user profile
    # schema; a partially applied migration leaves a profile the client cannot
    # parse. Refusing before the binary runs is what makes that state
    # unreachable rather than merely unlikely.
    cat > "${root}/bin/idrive" <<EOF
#!${bash}/bin/bash
set -euo pipefail

# The client's own dispatch is an exact hash lookup on \$ARGV[0] (not
# Getopt::Long), so only the first argument needs checking here; scanning
# every argument would misfire on, say, a backup path that happens to
# contain one of these strings as a substring. Abbreviations
# (--check-upd) and --check-update=value are not holes either: the exact
# hash lookup falls through to unknown_option for those, it does not reach
# chkupd. -C is a short alias for --check-update, translated by the
# binary's own %shorttocmd table before dispatch, so it is blocked
# identically to the long form.
first="\''${1:-}"
case "\$first" in
  --check-update|--handle-update|--launch-update|-C)
    echo "iDrive is managed by Nix; this build will not self-update." >&2
    echo "To pick up a new client version, bump the pin in nix/sources.json" >&2
    echo "and rebuild, or run 'nix run .#update'." >&2
    exit 1
    ;;
esac

# A fourth, positional entry point: the dashboard spawns
# "<binary> --utilities UPDATEFROMDASHBOARD dashboard &", which reaches the
# same doDirectAppUpdate() as --launch-update. Not expressible as a single
# -token case match, so checked separately.
if [ "\$first" = "--utilities" ]; then
  for arg in "\$@"; do
    if [ "\$arg" = "UPDATEFROMDASHBOARD" ]; then
      echo "iDrive is managed by Nix; this build will not self-update." >&2
      echo "To pick up a new client version, bump the pin in nix/sources.json" >&2
      echo "and rebuild, or run 'nix run .#update'." >&2
      exit 1
    fi
  done
fi

export LD_LIBRARY_PATH="${vendorLib}\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export PATH="${lib.makeBinPath [ coreutils bash gnutar gzip procps util-linux unixtools.hostname ]}\''${PATH:+:\$PATH}"
export TERM="\''${TERM:-xterm}"

# Make \$0 absolute without resolving through any symlink: loadAppPath runs
# during the client's own init, before any chdir, so a relative \$0 is safe
# today, but leaving it relative would make resolution depend on the
# caller's cwd instead of being immune to it the way the old hardcoded
# argv0 was. Prepending \$PWD, not realpath/readlink, is deliberate: the
# whole point is to preserve whatever \$0 actually is, symlink and all, not
# collapse it to its target.
#
# A bare word (no slash at all, e.g. \$0 == "idrive" from a caller that
# invoked us through PATH) is a fourth case, distinct from both the
# absolute and the slash-containing-relative ones: prepending \$PWD to it
# fabricates "\$PWD/idrive", a path that generally does not exist, is
# never a symlink, and trips the client's own \`unless(-l \$0)\` guard on
# --cron below regardless of how this wrapper itself was actually found.
# Resolve it through PATH instead with \`command -v\`, the same mechanism
# the shell itself just used to find this wrapper: for a package on PATH
# that lookup returns <pkg>/bin/idrive, which IS a symlink (this file's
# own public entry point), satisfying the guard exactly like the
# absolute-path case. \`|| true\` plus the emptiness check keep this safe
# under \`set -eu\` if PATH lookup finds nothing (falls back to the old,
# possibly-guard-tripping \$PWD/\$0 behavior rather than aborting the
# wrapper outright).
case "\$0" in
  /*)   idriveArgv0="\$0" ;;
  */*)  idriveArgv0="\$PWD/\$0" ;;
  *)    idriveArgv0="\$(command -v "\$0" 2>/dev/null || true)"
        [ -n "\$idriveArgv0" ] || idriveArgv0="\$PWD/\$0" ;;
esac

# exec -a propagates idriveArgv0 (this wrapper's own invocation path, made
# absolute above without resolving any symlink), rather than a path
# hardcoded to this build. Two client-side requirements both depend on that:
#
# 1. The client's own cron/service entry point refuses to run at all
#    unless \$0 names a filesystem symlink ("unless(-l \$0){...
#    saferetreat('you_cant_run_supporting_service')}", confirmed by
#    extracting that guard from the real binary). \$out/bin/idrive is a
#    symlink to this wrapper; a hardcoded \$0 pointing at this wrapper's own
#    regular-file location on disk is not, and always tripped that guard,
#    making --cron unusable through any entry point this package exposes.
#    The pre-Nix Docker image (see git history's start.sh) worked around the
#    exact same requirement by symlinking /etc/idrivecron to the real binary
#    and invoking --cron through that symlink, never through the plain path.
#    That still applies here: --cron specifically must be invoked through a
#    symlink such as \$out/bin/idrive. ${root}/bin/idrive is this wrapper's
#    own regular-file location, not a symlink, so calling --cron by that
#    exact path directly still trips the guard even though the wrapper
#    itself runs fine there for every other argument.
#
# 2. loadAppPath -> getAbsPath(\$0) -> dirname must still resolve to a
#    directory that contains this same protective wrapper, so self-
#    invocations the client builds internally (scheduleAutoUpdateCRON,
#    doDirectAppUpdate, isUpdateAvailable) stay routed through it instead of
#    reaching ${root}/bin/.idrive-unwrapped directly. getAbsPath resolves
#    symlinks (it is Perl's abs_path/realpath, not a literal string), so
#    even when \$0 is a symlink such as \$out/bin/idrive, dirname(getAbsPath
#    (\$0)) still lands on ${root}/bin - this wrapper's own directory - not
#    on the symlink's own location. Every public entry point this package
#    ships (\$out/bin/idrive, ${root}/bin/idrive itself, and anything
#    environment.systemPackages links to either of those) resolves the same
#    way; there is no path to .idrive-unwrapped that bypasses this wrapper.
exec -a "\$idriveArgv0" "${root}/bin/.idrive-unwrapped" "\$@"
EOF
    chmod +x "${root}/bin/idrive"

    # The public entrypoint is a symlink to the wrapper that now occupies
    # $root/bin/idrive, so both the documented $out/bin/idrive path and the
    # client's own internally resolved path point at the same wrapper.
    ln -s "${root}/bin/idrive" "$out/bin/idrive"

    # idevsutil needs environment only, so makeWrapper is enough.
    for prog in idevsutil idevsutil_dedup idevsutil_dedup_sync idevsutil_sync; do
      [ -e "${root}/idriveIt/$prog" ] || continue
      makeWrapper "${root}/idriveIt/$prog" "$out/bin/$prog" \
        --prefix LD_LIBRARY_PATH : "${vendorLib}" \
        --set-default TERM xterm
    done
  '';
}
