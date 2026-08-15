{ lib, writeShellApplication, coreutils, tzdata, idrive-client }:

let
  # Name of the writable application directory mkPrepare builds inside
  # stateDir. Exported below so callers can address the entry points it
  # creates (idrive, idrivecron) without hardcoding the name a second time.
  appSubdir = ".app";
in
rec {
  inherit appSubdir;

  # stateExpr is a shell expression, already quoted, that evaluates to the
  # state directory. A system service knows that path at build time and
  # passes a literal; a per-user service does not, because it depends on
  # $HOME of whichever user the unit runs for, so it passes an expression
  # resolved when the unit runs. Everything below is identical either way,
  # which is the point: one implementation, two ways of naming the
  # directory.
  mkPrepareWith = { stateExpr, timeZone }:
    writeShellApplication {
      name = "idrive-prepare";
      runtimeInputs = [ coreutils ];
      text = ''
        set -euo pipefail

        state=${stateExpr}
        appsrc="${idrive-client}/opt/IDriveForLinux/bin"
        shipped="${idrive-client}/opt/IDriveForLinux/idriveIt"
        app="$state/${appSubdir}"
        stamp="$state/.idrive-version"
        pkgstamp="$state/.idrive-package"

        mkdir -p "$state" "$app"

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

        # The client resolves its own installation directory from $0:
        # "loadAppPath { my $absFile = getAbsPath($0); $appPath =
        # getCatfile(dirname($absFile), ""); }" with getAbsPath being Perl's
        # abs_path, which fully resolves symlinks. Every entry point the
        # package itself exposes therefore lands appPath inside the
        # read-only store, and the client needs that directory writable and
        # needs to find "<appPath>/.serviceLocation" there naming the state
        # directory. Without it, loadServicePath() fails and the client
        # falls back to createServiceDirectory(), which retreats with
        # "Cannot open directory <store path> Permission denied" during
        # --account-setting, and to setServicePath(".") - the process cwd -
        # under --cron, so state never reaches stateDir at all.
        #
        # So build a writable application directory here: every entry of the
        # package's bin/ mirrored as a symlink (reads resolve into the store
        # exactly as before), plus two things that must not be symlinks:
        #
        #   idrive           a real-file copy of the update-blocking wrapper.
        #                    A symlink would make abs_path($0) resolve
        #                    straight back into the store and defeat the
        #                    whole point. Being a copy of the wrapper (not of
        #                    the raw binary) is what keeps getBinaryPath() -
        #                    "<appPath>/idrive", used by the client's own
        #                    scheduleAutoUpdateCRON, doDirectAppUpdate and
        #                    isUpdateAvailable - pointing at a wrapper that
        #                    still refuses to self-update.
        #   .serviceLocation the state directory, read by loadServicePath().
        #
        # and one thing that must be a symlink:
        #
        #   idrivecron       the daemon entry point. The client's cron/
        #                    service mode refuses to start unless $0 names a
        #                    symlink ("unless(-l $0){... saferetreat(
        #                    'you_cant_run_supporting_service')}"), which is
        #                    why upstream's old Dockerfile invoked --cron
        #                    through "ln -s .../bin/idrive /etc/idrivecron".
        #                    Its abs_path is the wrapper copy above, so
        #                    appPath still resolves here and not to the
        #                    store.
        #
        # Nothing writes into the mirrored store paths: setup's dependency
        # check would extract into "<appPath>/Idrivelib/dependencies/evsbin"
        # only when hasEVSBinary() finds no usable idevsutil in the state
        # directory, and the staging step above put them there first.
        shopt -s dotglob nullglob

        # Drop mirror entries left by a previously installed package, so a
        # package change cannot leave a stale name behind. Only symlinks
        # into the store are considered: idrivecron points inside this
        # directory, and anything the client itself writes here is a real
        # file.
        for f in "$app"/*; do
          [ -L "$f" ] || continue
          case "$(readlink "$f")" in
            "$appsrc"/*) ;;
            /nix/store/*) rm -f "$f" ;;
          esac
        done

        for f in "$appsrc"/*; do
          case "$(basename "$f")" in
            idrive | .serviceLocation | Idrivelib) continue ;;
          esac
          ln -sfn "$f" "$app/$(basename "$f")"
        done

        # Idrivelib gets mirrored rather than symlinked wholesale, because
        # the vendored Python helper resolves the service path from its own
        # location the same way the Perl side resolves appPath from $0. With
        # Idrivelib a symlink into the store, that resolution lands in the
        # read-only store, the helper never finds the request file the client
        # just wrote, and every authentication fails with "'helpers' object
        # has no attribute '_helpers__servicepath'". Copying only
        # dependencies/python is enough to fix it (19M rather than the whole
        # 38M tree), and was verified by watching that error turn into a
        # real server response once the helper could resolve itself.
        # A state directory prepared by an older build has Idrivelib as a
        # symlink, and the prune loop above deliberately keeps symlinks that
        # point at the current package, so this one has to go explicitly.
        # Without it mkdir -p would follow the link and the writes below
        # would land in the read-only store.
        [ -L "$app/Idrivelib" ] && rm -f "$app/Idrivelib"
        mkdir -p "$app/Idrivelib/dependencies"
        for f in "$appsrc"/Idrivelib/*; do
          case "$(basename "$f")" in
            dependencies) continue ;;
          esac
          ln -sfn "$f" "$app/Idrivelib/$(basename "$f")"
        done
        for f in "$appsrc"/Idrivelib/dependencies/*; do
          case "$(basename "$f")" in
            python) continue ;;
          esac
          ln -sfn "$f" "$app/Idrivelib/dependencies/$(basename "$f")"
        done

        if [ ! -e "$app/Idrivelib/dependencies/python/.idrive-package" ] \
          || [ "$(cat "$app/Idrivelib/dependencies/python/.idrive-package")" != "${idrive-client}" ]; then
          rm -rf "$app/Idrivelib/dependencies/python"
          cp -a "$appsrc/Idrivelib/dependencies/python" "$app/Idrivelib/dependencies/python"
          chmod -R u+w "$app/Idrivelib/dependencies/python"
          printf '%s\n' "${idrive-client}" > "$app/Idrivelib/dependencies/python/.idrive-package"
        fi

        shopt -u dotglob nullglob

        # Removed first: the store copy is mode 0555, so a plain overwrite
        # of a previous run's copy would fail for a non-root caller.
        rm -f "$app/idrive"
        install -m 0755 "$appsrc/idrive" "$app/idrive"
        ln -sfn "$app/idrive" "$app/idrivecron"
        printf '%s\n' "$state" > "$app/.serviceLocation"

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

  # The single entry point both backends run the client through, and the
  # one that goes on PATH for interactive use. It prepares the writable
  # application directory (see mkPrepare) and then execs the copy of the
  # wrapper that lives there, so the client resolves its own appPath to a
  # writable directory instead of the store. --cron is routed through the
  # idrivecron symlink because the client refuses that mode unless $0 is a
  # symlink; everything else runs through the regular-file copy, whose
  # abs_path is the same directory either way.
  mkLauncherWith = { name, stateExpr, timeZone }:
    let
      prepare = mkPrepareWith { inherit stateExpr timeZone; };
    in
    writeShellApplication {
      inherit name;
      text = ''
        set -euo pipefail

        "${prepare}/bin/idrive-prepare"

        app=${stateExpr}/${appSubdir}
        if [ "''${1:-}" = "--cron" ]; then
          exec "$app/idrivecron" "$@"
        fi
        exec "$app/idrive" "$@"
      '';
    };

  # First-run account setup, driven from a secret instead of a person.
  #
  # The client has no non-interactive login: --login opens a menu, and
  # --account-setting --auto-setup only skips the redraws, still reading
  # every answer from standard input (getUserChoice is "$input = <STDIN>").
  # So the answers are fed in order. The order was established by running
  # setup and watching it: authentication method, then username. The
  # password prompt follows, but only once the username validates against
  # the server, so it cannot be observed without a real account.
  #
  # That is the honest limit of this: the leading answers are verified, the
  # tail is not. Standard input is therefore closed after the three answers
  # rather than padded with guesses, so an unexpected prompt reaches EOF and
  # fails the run instead of silently accepting a wrong answer, and the
  # result is checked afterwards rather than assumed.
  mkSetup = { stateExpr, launcher, launcherBin, username ? null, usernameFile ? null, passwordFile }:
    writeShellApplication {
      name = "idrive-setup";
      runtimeInputs = [ coreutils ];
      text = ''
        set -euo pipefail

        state=${stateExpr}
        stamp="$state/.setup-done"

        if [ -e "$stamp" ]; then
          echo "idrive-setup: already configured, nothing to do" >&2
          exit 0
        fi

        if [ ! -r ${passwordFile} ]; then
          echo "idrive-setup: cannot read the password file ${passwordFile}" >&2
          echo "idrive-setup: it must exist and be readable by this service" >&2
          exit 1
        fi

        password=$(cat ${passwordFile})
        password=''${password%%[[:space:]]}
        if [ -z "$password" ]; then
          echo "idrive-setup: ${passwordFile} is empty" >&2
          exit 1
        fi

        ${lib.optionalString (usernameFile != null) ''
          # Read at runtime rather than baked into this script, so the
          # account name never lands in the world-readable Nix store.
          if [ ! -r ${usernameFile} ]; then
            echo "idrive-setup: cannot read the username file ${usernameFile}" >&2
            echo "idrive-setup: it must exist and be readable by this service" >&2
            exit 1
          fi
          username=$(cat ${usernameFile})
          username=''${username%%[[:space:]]}
          if [ -z "$username" ]; then
            echo "idrive-setup: ${usernameFile} is empty" >&2
            exit 1
          fi
        ''}${lib.optionalString (usernameFile == null) ''
          username=${lib.escapeShellArg username}
        ''}

        # 1 selects "Login using IDrive credentials"; the alternative is SSO,
        # which this cannot drive because it continues in a browser.
        out=$(printf '1\n%s\n%s\n' "$username" "$password" \
          | timeout 300 "${launcher}/bin/${launcherBin}" --account-setting --auto-setup 2>&1 || true)

        # Never let the secret reach a log, whatever the client printed.
        out=''${out//"$password"/[redacted]}

        if printf '%s' "$out" | grep -q '_helpers__servicepath'; then
          echo "idrive-setup: the vendored Python helper could not resolve its" >&2
          echo "service path, so no login can succeed. This is a packaging" >&2
          echo "fault, not a credential problem." >&2
          printf '%s\n' "$out" >&2
          exit 1
        fi

        if printf '%s' "$out" | grep -qiE 'failed to authenticate|invalid username or password'; then
          echo "idrive-setup: IDrive rejected the credentials for $username" >&2
          printf '%s\n' "$out" >&2
          exit 1
        fi

        # Only the client writes under user_profile, so its absence means
        # setup did not get far enough to register anything, whatever the
        # output looked like.
        if [ ! -d "$state/user_profile" ] || [ -z "$(ls -A "$state/user_profile" 2>/dev/null)" ]; then
          echo "idrive-setup: setup finished without creating a profile." >&2
          echo "The prompt sequence may have changed in this client version." >&2
          printf '%s\n' "$out" >&2
          exit 1
        fi

        printf '%s\n' "${idrive-client.version}" > "$stamp"
        echo "idrive-setup: account linked" >&2
      '';
    };

  # System-wide use: the state directory is a fixed path chosen by the
  # module, known when the package is built.
  mkPrepare = { stateDir, timeZone }:
    mkPrepareWith { stateExpr = ''"${stateDir}"''; inherit timeZone; };

  mkLauncher = { stateDir, timeZone }:
    mkLauncherWith { name = "idrive"; stateExpr = ''"${stateDir}"''; inherit timeZone; };

  # Per-user use: the state directory follows the XDG base directory
  # specification under the invoking user's own home, so each user gets a
  # separate iDrive account, profile and schedule with no privilege
  # involved: their own uid already owns everything they back up.
  #
  # The default has to be spelled out rather than relying on the unit's
  # StateDirectory=, because the launcher also runs outside systemd for
  # interactive account setup, where no unit environment exists.
  userStateExpr = ''"''${XDG_STATE_HOME:-$HOME/.local/state}/idrive"'';

  mkUserPrepare = { timeZone }:
    mkPrepareWith { stateExpr = userStateExpr; inherit timeZone; };

  # Named idrive-user, not idrive, on purpose. A machine can run both a
  # system-wide backup account and per-user accounts, and two different
  # commands cannot share one name on PATH. A command whose meaning depends
  # on who typed it would be worse than a longer name.
  mkUserLauncher = { timeZone }:
    mkLauncherWith { name = "idrive-user"; stateExpr = userStateExpr; inherit timeZone; };
}
