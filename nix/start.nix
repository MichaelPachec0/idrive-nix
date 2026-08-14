{ writeShellApplication, coreutils, tzdata, idrive-client }:

{
  mkPrepare = { stateDir, timeZone }:
    writeShellApplication {
      name = "idrive-prepare";
      runtimeInputs = [ coreutils ];
      text = ''
        set -euo pipefail

        state="${stateDir}"
        shipped="${idrive-client}/opt/IDriveForLinux/idriveIt"
        stamp="$state/.idrive-version"
        pkgstamp="$state/.idrive-package"

        mkdir -p "$state"

        # The vendor tree ships content (idevsutil binaries) inside the same
        # directory that holds mutable state (user_profile, cache,
        # idrivecrontab.json). Upstream works around this by keeping an
        # idriveIt.orig copy and restoring on every boot, which leaves bind
        # mount users with partial trees. Sync only the shipped files, only
        # when the package changes, and never touch state.
        #
        # Keyed on the package's store path, not on its version string. The
        # staged copies are real files carrying RUNPATHs into the store, so
        # they go stale whenever the store path changes - which a weekly
        # `nix flake update` does routinely, with the client's own version
        # still reading 3.14.0. A version-keyed gate skips re-staging then,
        # and the next `nix-collect-garbage -d` leaves the staged transfer
        # utilities pointing at deleted libraries: backups fail at runtime
        # with nothing wrong at build time. The version stamp is still
        # written, separately and unconditionally, because it is the
        # human-readable record of what is staged (and what the module's
        # own tests look for); it is just not what decides the sync.
        if [ ! -f "$pkgstamp" ] || [ "$(cat "$pkgstamp")" != "${idrive-client}" ]; then
          if [ -d "$shipped" ]; then
            for f in "$shipped"/idevsutil*; do
              [ -e "$f" ] || continue
              install -m 0755 "$f" "$state/$(basename "$f")"
            done
          fi
          printf '%s\n' "${idrive-client}" > "$pkgstamp"
        fi
        printf '%s\n' "${idrive-client.version}" > "$stamp"

        # The client expects this file to exist before it starts. Upstream
        # requires bind mount users to touch it by hand first.
        [ -f "$state/idrivecrontab.json" ] || : > "$state/idrivecrontab.json"

        # Validate the timezone eagerly so a typo in services.idrive.timeZone
        # (or the image's build-time timeZone) surfaces here, at prepare
        # time, rather than silently producing backups stamped in UTC.
        # Runtime TZ delivery to the running daemon is the caller's job, not
        # this script's: the NixOS module sets it via the systemd unit's
        # environment, and the image sets it via its container env. Do not
        # re-add an `export TZ` here: it would die with this short-lived
        # process before the daemon ever started.
        if [ ! -f "${tzdata}/share/zoneinfo/${timeZone}" ]; then
          echo "idrive-prepare: unknown timezone '${timeZone}': no such zoneinfo file ${tzdata}/share/zoneinfo/${timeZone}" >&2
          exit 1
        fi
      '';
    };
}
