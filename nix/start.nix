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

        mkdir -p "$state"

        # The vendor tree ships content (idevsutil binaries) inside the same
        # directory that holds mutable state (user_profile, cache,
        # idrivecrontab.json). Upstream works around this by keeping an
        # idriveIt.orig copy and restoring on every boot, which leaves bind
        # mount users with partial trees. Sync only the shipped files, only
        # when the package version changes, and never touch state.
        if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "${idrive-client.version}" ]; then
          if [ -d "$shipped" ]; then
            for f in "$shipped"/idevsutil*; do
              [ -e "$f" ] || continue
              install -m 0755 "$f" "$state/$(basename "$f")"
            done
          fi
          echo "${idrive-client.version}" > "$stamp"
        fi

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
