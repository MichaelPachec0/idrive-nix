{ lib, writeShellApplication, coreutils, tzdata, idrive-client }:

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

        # Timezone. Backup schedules and log timestamps follow it.
        if [ -f "${tzdata}/share/zoneinfo/${timeZone}" ]; then
          export TZ="${timeZone}"
        fi
      '';
    };
}
