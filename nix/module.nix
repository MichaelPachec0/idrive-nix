{ config, lib, pkgs, ... }:

let
  cfg = config.services.idrive;
  inherit (lib) mkIf mkOption mkEnableOption mkPackageOption types;

  startLib = pkgs.callPackage ./start.nix { idrive-client = cfg.package; };

  prepare = startLib.mkPrepare {
    inherit (cfg) stateDir timeZone;
  };

  # The interactive entry point: it runs the prepare step and then execs
  # the client out of the writable application directory that step builds
  # inside stateDir, so the client's own appPath resolution lands there
  # instead of in the read-only store (see nix/start.nix for the
  # mechanism). The unit below reaches the same prepared directory through
  # ExecStartPre plus a direct ExecStart, so interactive setup and the
  # daemon cannot end up resolving state differently.
  launcher = startLib.mkLauncher {
    inherit (cfg) stateDir timeZone;
  };

  # The per-user counterpart, resolving its state directory under the
  # invoking user's home rather than a fixed system path.
  userLauncher = startLib.mkUserLauncher {
    inherit (cfg) timeZone;
  };

  # The client's scheduler locks a path it hardcodes, /var/run/idrivecron.lock,
  # and exits 0 if it cannot open it, which stops all scheduled backups while
  # the unit reports success. /run is read-only under ProtectSystem=strict and
  # root-only anyway, so the path is made a symlink into stateDir, which the
  # service can already write. A ReadWritePaths entry cannot do this: it fails
  # the unit with 226/NAMESPACE whenever the path is missing, and the client
  # can delete it. The + runs this outside the sandbox, on every start.
  cronLockSetup = pkgs.writeShellScript "idrive-cron-lock" ''
    ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg "${cfg.stateDir}/.cron.lock"} /run/idrivecron.lock
  '';

  permissionTools = pkgs.callPackage ./permission-tools.nix { };

  restricted = cfg.backend == "native" && cfg.user == "root" && cfg.restrictRoot;
  useView = cfg.backend == "native" && cfg.user != "root" && cfg.readAllFiles;
  viewRoot = "/run/idrive-view";

  # Being uid 0 passes the client's Perl `-r` check, which is what a non-root
  # user with CAP_DAC_READ_SEARCH fails, and the capability does the real reads.
  # Dropping capabilities alone is not a sandbox, though. uid 0 still owns the
  # raw disks, /proc/sys, and systemd's private socket (a way out to full root),
  # and it can signal any other root process. Each line closes one of those.
  # AF_UNIX stays out for the sockets; the client does not need it.
  rootSandbox = {
    CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    PrivatePIDs = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" ];
    # Hidden unless asked for: the sandbox would otherwise back up a path in
    # backupPaths as empty, and report success.
    InaccessiblePaths = map (p: "-${p}") (lib.filter
      (hidden: !lib.any (p: lib.hasPrefix hidden p || lib.hasPrefix p hidden) cfg.backupPaths)
      [ "/etc/shadow" "/etc/ssh" ]);
  };

  clientSandbox = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = "read-only";
    PrivateTmp = true;
    ReadWritePaths = [ cfg.stateDir ] ++ map (p: "-${p}") cfg.writablePaths;
  };

  clientEnvironment = {
    # uid 0's own home is read-only in here, and the client writes to $HOME.
    HOME = cfg.stateDir;
    TZ = cfg.timeZone;
    LC_ALL = "en_US.UTF-8";
  };

  # What the watcher and the backup job share, so they see the same files.
  jobUnit = {
    environment = clientEnvironment;
    unitConfig.WantsMountsFor = cfg.backupPaths ++ cfg.writablePaths;
    serviceConfig = clientSandbox // {
      User = cfg.user;
      Group = cfg.group;
    } // lib.optionalAttrs restricted rootSandbox
    // lib.optionalAttrs useView {
      BindReadOnlyPaths = map (p: "-${viewRoot}${p}:${p}") cfg.backupPaths;
    } // lib.optionalAttrs (cfg.supplementaryGroups != [ ]) {
      SupplementaryGroups = cfg.supplementaryGroups;
    } // lib.optionalAttrs (cfg.umask != null) {
      UMask = cfg.umask;
    };
  };

  backupJob = pkgs.callPackage ./backup-job.nix { } {
    client = "${namedLauncher}/bin/idrive";
    inherit (cfg) stateDir;
    paths = cfg.backupPaths;
  };

  # The same limits for a client run by hand, which would otherwise have every
  # capability root has.
  restrictedLauncher = pkgs.writeShellApplication {
    name = "idrive-restricted";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      exec systemd-run --pty --wait --collect --quiet \
        ${lib.escapeShellArgs (lib.concatLists (lib.mapAttrsToList
          (name: value: [
            "--property=${name}=${
              if builtins.isBool value then lib.boolToString value
              else if builtins.isList value then lib.concatStringsSep " " value
              else value}"
          ])
          (clientSandbox // rootSandbox)))} \
        ${lib.escapeShellArgs (lib.mapAttrsToList (name: value: "--setenv=${name}=${value}") clientEnvironment)} \
        --setenv=TERM="''${TERM:-xterm}" \
        ''${EDITOR:+--setenv=EDITOR="$EDITOR"} \
        -- ${namedLauncher}/bin/idrive "$@"
    '';
  };

  automaticSetup =
    (cfg.username != null || cfg.usernameFile != null) && cfg.passwordFile != null;

  setup = startLib.mkSetup {
    stateExpr = ''"${cfg.stateDir}"'';
    launcher = namedLauncher;
    launcherBin = "idrive";
    inherit (cfg) username usernameFile passwordFile encryptionKeyFile;
  };

  # deviceName has to reach the interactive command as well as the unit, not
  # just the unit: the name is fixed when the client first registers the
  # machine, and that registration happens during interactive account setup.
  # A unit-only setting would leave setup registering the hostname and the
  # daemon later claiming a different name.
  namedLauncher =
    if cfg.deviceName == null then launcher
    else
      pkgs.runCommand "idrive-named" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p "$out/bin"
        makeWrapper ${launcher}/bin/idrive "$out/bin/idrive" \
          --set IDRIVE_DEVICE_NAME ${lib.escapeShellArg cfg.deviceName}
      '';

  # The per-user case cannot bake a single name, because one launcher serves
  # every user in userServices. It looks the caller up instead, so the unit
  # and an interactive run resolve identically.
  namedUserLauncher =
    if cfg.userDeviceNames == { } then userLauncher
    else
      pkgs.writeShellApplication {
        name = "idrive-user";
        text = ''
          case "$(id -un)" in
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList
            (user: name: ''  ${lib.escapeShellArg user}) export IDRIVE_DEVICE_NAME=${lib.escapeShellArg name} ;;'')
            cfg.userDeviceNames)}
          esac
          exec ${userLauncher}/bin/idrive-user "$@"
        '';
      };

  # Existing profiles address backup sets as /source/1, /source/2, and so on,
  # because that is how the container maps them. Recreating those names on the
  # host lets a migrated profile keep working untouched.
  sourceLinks = lib.imap1
    (i: path: "L+ /source/${toString i} - - - - ${path}")
    cfg.backupPaths;

  usesDefaultStateDir = cfg.stateDir == "/var/lib/idrive";

  # Matches nix/image.nix's `dockerTools.buildLayeredImage { name =
  # "idrive-docker"; tag = idrive-client.version; ... }` exactly. The image
  # derivation itself is not an input to this module (a NixOS module only
  # receives config/lib/pkgs from the module system, not arbitrary flake
  # outputs), so the default is tied to cfg.package.version instead: as long
  # as services.idrive.package is the same idrive-client build that produced
  # the image, this string and the image's own imageName:imageTag passthru
  # agree. A user building the image from a different package is expected to
  # set services.idrive.container.image explicitly.
  defaultContainerImage = "idrive-docker:${cfg.package.version}";
in
{
  options.services.idrive = {
    enable = mkEnableOption "the IDrive Linux backup client";

    acceptTerms = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Confirms that you have read and accept IDrive's terms and
        conditions, <https://www.idrive.com/terms-and-conditions>.

        While this is false the module does no work: it creates no
        services, launchers, containers or users, whatever else is set, and
        evaluation prints a warning saying so. A warning rather than an
        error, so that a host stays deployable while the terms are reviewed.
      '';
    };

    package = mkPackageOption pkgs "idrive-client" {
      extraDescription = ''
        This package is not in nixpkgs; it comes from this flake's own
        `overlays.default`, or must be set explicitly. Enabling this module
        without applying the overlay leaves the default unresolvable and
        fails evaluation with an "attribute 'idrive-client' missing" error.
      '';
    };

    backend = mkOption {
      type = types.enum [ "native" "container" ];
      default = "native";
      description = ''
        Run the client directly under systemd, or inside the Nix-built OCI
        image. The container backend maps backupPaths to /source/N exactly as
        the upstream image does.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/idrive";
      description = "Mutable state: user_profile, cache, idrivecrontab.json.";
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = ''
        Applies only to backend = "native". A backup agent can only read
        what its user can read. root is the default for whole-system
        backups; a dedicated user is safer when the backup set is narrow.
        When createUser is true (the default) and this is not "root", the
        module creates that user itself; set createUser = false if you
        manage the account yourself. Under backend = "container" the
        client runs as whatever user is baked into the image (root), not a
        host user this module could substitute in; setting user away from
        its default there has no effect and fails evaluation.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = ''
        Applies only to backend = "native": group the service runs as.
        When createUser is true (the default) and this is not "root", the
        module creates that group too. Under backend = "container" this
        has no effect, for the same reason as user above, and fails
        evaluation if set away from its default there.
      '';
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Applies only to backend = "native". When true and user is not
        "root", define users.users.<user> as a system user with group as
        its primary group (and users.groups.<group> too, when that is also
        not "root"). Set this to false if you manage that account yourself
        (for example because it already exists for another reason), or if
        user stays at its default of "root", for which this module never
        defines users.users.root.
      '';
    };

    supplementaryGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "media" ];
      description = ''
        Applies only to backend = "native". Extra groups the service
        belongs to, on top of group above. Use this when the data under
        backupPaths is already readable by a group the service user can
        join; it grants exactly that group's read access and nothing more.
        The file's own group has to be one of these: the client ignores
        group grants made through an ACL. For anything else, see
        readAllFiles below.

        These are applied twice, deliberately: to the unit as
        SupplementaryGroups, which covers the daemon, and (when createUser
        is true) to the account as extraGroups, which covers running the
        client by hand for account setup. The unit property alone would
        leave interactive setup without the access the daemon has, since
        SupplementaryGroups never touches /etc/group. With createUser =
        false, only the unit grant applies and the group membership of the
        account is yours to manage.
      '';
    };

    readAllFiles = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Applies only to backend = "native" with a non-root user, and needs
        scheduledBackup. Gives the client a read-only view of backupPaths
        in which it can read everything, while it stays an unprivileged
        user.

        The view is a bindfs mount made by a small root service with no
        network, which never runs client code. It lives under a root-only
        directory, and the backup units bind it over the real paths inside
        their own mount namespace, so backup sets keep their real paths and
        no other user can reach it. Nothing on the real files changes.

        This replaces a CAP_DAC_READ_SEARCH grant, which did not work: the
        client tests every path with Perl's `-r`, which reads the mode bits
        and ignores capabilities and ACLs, so it skipped those files and
        still reported success. A client run by hand gets no view; only the
        units do.
      '';
    };

    restrictRoot = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Applies only to backend = "native" with user = "root". Runs the
        client's units as uid 0 with CAP_DAC_READ_SEARCH as their only
        capability, in a sandbox: it can read everything and write only
        stateDir and writablePaths, and it has no raw devices, no way to
        reach systemd or D-Bus, and no view of other processes.

        Reading everything is still the point of it, so file contents remain
        as exposed to the client as with plain root. /etc/shadow and /etc/ssh
        are hidden unless backupPaths names them.

        Setting this to false gives the client full root, which it needs
        only to write into a writablePaths directory owned by someone else.
        Run the client by hand under the same limits with idrive-restricted;
        plain `sudo idrive` has every capability root has.
      '';
    };

    scheduledBackup = {
      enable = mkEnableOption ''
        backups from a systemd timer instead of the client's scheduler, which
        exits at once for any user but root. backupPaths becomes the backup
        set, and replaces whatever the client holds. A run fails the unit when
        the job failed, when no job ran, or when any path was left out, none of
        which the client's exit code or job status shows
      '';

      schedule = mkOption {
        type = types.str;
        default = "daily";
        example = "*-*-* 02:00:00";
        description = "When to back up, as a systemd OnCalendar value.";
      };

      timeout = mkOption {
        type = types.str;
        default = "12h";
        description = ''
          How long a run may take. With the network down the client waits
          forever rather than failing, so this is also how long such a run
          holds on before the unit fails. Raise it if a first backup needs
          longer.
        '';
      };
    };

    umask = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0077";
      description = ''
        Applies only to backend = "native". Sets the unit's UMask, which
        governs the permission bits of files the client creates, most
        notably restored files. Left null (the default) so this module
        never changes existing restore behavior on its own; systemd's own
        default of 0022 then applies, which means a file that was mode
        0600 before backup can come back 0644 on restore, readable by
        anyone who can read the restore location. See the README's
        permission model section for why restoring the original mode and
        ownership exactly is not something this option (or any
        non-root-capable setup) can guarantee.
      '';
    };

    timeZone = mkOption {
      type = types.str;
      default = if config.time.timeZone != null then config.time.timeZone else "Etc/UTC";
      description = "Timezone for backup schedules and log timestamps.";
    };

    backupPaths = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [ "/srv/data" "/home/alice/documents" ];
      description = ''
        Paths the service may read. With scheduledBackup this is the backup
        set. Without it this does NOT choose what gets backed up: the client
        keeps its backup set in its own state, set with
        `idrive --edit-job-sets backup`. On the native backend this gives
        mount ordering and legacySourceLinks; on the container backend it
        mounts each path at /source/N.
      '';
    };

    permissionManifest = {
      paths = mkOption {
        type = types.listOf types.path;
        default = [ ];
        example = [ "/srv/data" ];
        description = ''
          Directories to record modes, owners, ACLs and symlinks for. The
          client stores none of these: a restored file comes back 0777
          root:root, and a symlink does not come back.

          Each path gets .idrive-perms.acl and .idrive-links written inside
          it, so a directory in the backup set carries its own record. This
          does not add anything to the backup set, which is set with
          `idrive --edit-job-sets backup`.

          After a restore, run `idrive-restore-permissions` as root on the
          restored directory.
        '';
      };

      schedule = mkOption {
        type = types.str;
        default = "hourly";
        example = "*-*-* 01:30:00";
        description = ''
          When to rewrite the records, as a systemd OnCalendar value. A backup
          carries the record from the last run, so run this before the
          backup, and anything newer than that record stays 0777 on restore.
        '';
      };
    };

    username = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "someone@example.com";
      description = ''
        IDrive account to link this machine to. Set together with
        passwordFile to have the module perform first-run account setup
        instead of an operator running it by hand.

        Null (the default) leaves setup interactive, which is what the
        client is designed for.
      '';
    };

    usernameFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/idrive-username";
      description = ''
        File holding the account name, as an alternative to username, read
        at setup time rather than baked into the setup script. Use this to
        keep the account name out of the Nix store, which is world
        readable, by pointing it at a secret your secret manager decrypts
        at activation.

        Set either this or username, not both.

        Worth knowing: this keeps the name out of the store, not out of the
        journal. The client prints the account name in its own messages
        (Failed to authenticate user "..."), so a failed setup will still
        show it. Treat it as an identifier worth not publishing rather than
        as a secret in the sense the password is.
      '';
    };

    passwordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/idrive-password";
      description = ''
        File holding the password for username, read at setup time. Point
        this at a secret your secret manager decrypts at activation
        (sops-nix or agenix), not at a file in the Nix store: everything in
        the store is world-readable.

        The file should be mode 0400 and owned by services.idrive.user. Its
        contents are the password and nothing else; trailing whitespace is
        stripped, an empty file is an error.

        The module never copies this file, and the password stays out of
        the process table and the unit's environment. The client does keep
        credentials of its own: a successful login writes an encoded,
        unsalted credential under stateDir, so stateDir is as sensitive as
        this file.

        The client has no non-interactive login of its own, so the module
        runs it on a pseudo-terminal and answers its prompts by their exact
        text, which is a property of the client rather than a documented
        interface. Setup stops rather than guessing: it fails on any prompt
        it does not recognise, on two-factor accounts, and when an account
        already has backup locations to choose between, and it tries a
        password once per run, so once per boot until it succeeds. In those
        cases run setup by hand once.

        The file is read only until setup has succeeded. Changing the
        password afterwards does not reach the client; see the README.
      '';
    };

    encryptionKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/idrive-encryption-key";
      description = ''
        File holding your IDrive private encryption key, for accounts that
        use one instead of IDrive's own key. Read at setup time, like
        passwordFile. The client keeps its own encoded copy under stateDir.

        Null (the default) answers IDrive's setup prompt with the default
        encryption key, which is what an account without a private key
        wants. Setting it answers with the private key instead and supplies
        the key.

        The key cannot contain whitespace; IDrive rejects that itself, and
        this module checks before sending anything so the failure arrives
        without a round trip.

        This decides how backups are encrypted at the point the account is
        first configured, and IDrive cannot recover data encrypted with a
        private key it never had. Losing this file means losing the
        backups, so keep it wherever you keep things you cannot regenerate.
      '';
    };

    deviceName = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "nas-backup";
      description = ''
        Name this machine shows under in the iDrive web interface, for the
        system service. Null (the default) leaves the client's own
        behavior alone, which is to use the machine's hostname.

        iDrive calls this the backup location, and it is fixed when the
        client first registers the machine: renaming afterwards is done
        through the web interface, not by changing this option, because
        the name is server-side state by then. Set it before running
        account setup for the first time.

        The client accepts letters, digits, underscore and hyphen only,
        four to sixty-four characters. Anything else is rejected at setup
        time, so spaces and dots do not work here.

        There is no CLI flag that sets the nickname, so this works by
        answering the two commands the client asks for the hostname
        (uname -n, and hostname as its fallback). Nothing else about the
        system is affected, and other uname queries, including the
        architecture check that picks the transfer binaries, are passed
        through untouched.
      '';
    };

    userDeviceNames = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { alice = "laptop-alice"; };
      description = ''
        Per-user equivalent of deviceName, keyed by user name, for users
        listed in userServices.

        Worth setting when more than one user backs up from one machine:
        without it every per-user service registers under the same
        hostname, and the iDrive web interface shows several devices with
        one name and no way to tell them apart. Users not listed here keep
        the client's default.

        Same character rules as deviceName, and the same timing: the name
        is fixed when that user's client first registers.
      '';
    };

    userServices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alice" "bob" ];
      description = ''
        Users to run a per-user iDrive service for, as a systemd user
        service. Each listed user gets their own iDrive account, profile,
        schedule and state directory (under XDG_STATE_HOME, so
        ~/.local/state/idrive by default), independent of every other user
        and of the system-wide service.

        This is the right shape when separate people back up their own
        files with separate iDrive accounts. No privilege is involved:
        each user's own uid already owns what it backs up, so none of
        readAllFiles, supplementaryGroups or ACLs is needed, and restoring
        into their own home needs no writablePaths entry either. The
        system-wide service is the other shape: one account covering the
        whole machine, which is what needs those options.

        Both can run on the same machine. They are separate services with
        separate state, and the interactive command differs: idrive for the
        system service, idrive-user for a per-user one, because two
        different commands cannot share one name on PATH.

        Lingering is enabled for each listed user. Without it their user
        manager stops at logout and their backups stop with it, which is
        not a property anyone would want to discover from a missing
        restore point.
      '';
    };

    writablePaths = mkOption {
      type = types.listOf types.path;
      default = [ ];
      example = [ "/home/alice/restored" ];
      description = ''
        Applies only to backend = "native". Paths the service may write to,
        on top of stateDir, added to the unit's ReadWritePaths. Restore
        targets go here.

        Without this, restores fail before file permissions are even
        consulted: the unit runs with ProtectSystem = "strict" and
        ProtectHome = "read-only", so the whole filesystem including /home
        is read-only inside its mount namespace. ReadWritePaths takes
        priority over both, so listing a path here reopens exactly that
        path for writing and nothing else. Restoring into a user's own home
        needs the home directory, or a subdirectory of it, listed here.

        This governs only whether the write is permitted by the sandbox.
        What the restored files end up owned by, and with which mode, is a
        separate question; see the README's permission model section.
      '';
    };

    legacySourceLinks = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Applies only to backend = "native". Create /source/N symlinks to
        backupPaths, matching the old Docker image's layout, so backup sets
        configured against that image keep working after migrating to the
        native backend. The container backend gets /source/N from its own
        volume mappings instead, so this option has nothing to do there;
        setting it alongside backend = "container" is a configuration error
        and fails evaluation.
      '';
    };

    container = {
      runtime = mkOption {
        type = types.enum [ "podman" "docker" ];
        default = "podman";
        description = "Container runtime used by the container backend.";
      };

      imageFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Image tarball to load before running the container, normally the
          flake's idrive-image output. Loading from a file avoids needing a
          registry at all; the image reference (see the `image` option) must
          still name the same image and tag this tarball contains.
        '';
      };

      image = mkOption {
        type = types.str;
        default = defaultContainerImage;
        defaultText = lib.literalExpression ''"idrive-docker:''${package.version}"'';
        description = ''
          Image reference to run, as "name:tag". Defaults to this flake's
          own OCI image (nix/image.nix), tagged with the running package's
          version, which is how that image is actually built and how
          `imageFile` above is expected to be loaded. Override this when
          pointing at a different image, e.g. one pulled from a registry.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(cfg.enable && cfg.backend == "container" && cfg.legacySourceLinks);
          message = ''
            services.idrive.legacySourceLinks has no effect under backend =
            "container": /source/N there comes from the container's own
            volume mappings (built from backupPaths), not host symlinks.
            Unset legacySourceLinks, or switch backend to "native".
          '';
        }
        {
          assertion = !(cfg.enable && cfg.backend == "container" && (cfg.user != "root" || cfg.group != "root"));
          message = ''
            services.idrive.user/group have no effect under backend =
            "container": the containerized client always runs as the
            image's own user (root), fixed at image build time, not a host
            user or group this module's systemd unit would otherwise run
            as. Unset user/group (leave them at "root"), or switch backend
            to "native".
          '';
        }
        {
          assertion = !(cfg.enable && cfg.backend == "container" && cfg.supplementaryGroups != [ ]);
          message = ''
            services.idrive.supplementaryGroups has no effect under
            backend = "container", for the same reason as user/group
            above. Unset it, or switch backend to "native".
          '';
        }
        {
          assertion = !(cfg.enable && cfg.backend == "container" && cfg.readAllFiles);
          message = ''
            services.idrive.readAllFiles has no effect under backend =
            "container": the containerized client always runs as the
            image's own root user, which can already read everything.
            Unset it, or switch backend to "native".
          '';
        }
        {
          assertion = !(cfg.enable && useView && !cfg.scheduledBackup.enable);
          message = ''
            services.idrive.readAllFiles needs scheduledBackup.enable: the view
            is bound into the backup units, and a non-root client has no other
            unit that backs up.
          '';
        }
        {
          assertion = !(cfg.enable && cfg.scheduledBackup.enable
            && (cfg.backend != "native" || cfg.backupPaths == [ ]));
          message = ''
            services.idrive.scheduledBackup needs backend = "native" and at
            least one entry in backupPaths, which becomes the backup set.
          '';
        }
        {
          assertion = !(cfg.enable && cfg.backend == "container" && cfg.umask != null);
          message = ''
            services.idrive.umask has no effect under backend =
            "container": this module does not set UMask on the
            containerized unit. Unset it, or switch backend to "native".
          '';
        }
        {
          assertion = !(cfg.username != null && cfg.usernameFile != null);
          message = ''
            services.idrive.username and services.idrive.usernameFile name
            the same thing two ways. Set username for a plain value, or
            usernameFile to read it at setup time and keep it out of the
            Nix store, but not both.
          '';
        }
        {
          assertion =
            (cfg.username == null && cfg.usernameFile == null)
            == (cfg.passwordFile == null);
          message = ''
            An account name (services.idrive.username or usernameFile) and
            services.idrive.passwordFile go together: either set both, to
            have this module perform account setup, or neither, to do it
            interactively. Setting one alone would leave setup half
            specified and still waiting for a person.
          '';
        }
        {
          assertion = !(cfg.encryptionKeyFile != null && cfg.passwordFile == null);
          message = ''
            services.idrive.encryptionKeyFile only takes effect during the
            account setup this module performs, which needs passwordFile
            (and username or usernameFile) as well. On its own it would
            answer a prompt nobody reaches. Set the credentials too, or run
            setup interactively and supply the key there.
          '';
        }
        {
          assertion = !(cfg.enable && cfg.backend == "container"
            && (cfg.username != null || cfg.passwordFile != null));
          message = ''
            services.idrive.username and passwordFile drive the native
            backend's setup unit, which the container backend does not have:
            its client runs inside the image with its own entry point. Run
            account setup against the container as the README describes, or
            switch backend to "native".
          '';
        }
        {
          assertion = !(cfg.enable && cfg.backend == "container" && cfg.writablePaths != [ ]);
          message = ''
            services.idrive.writablePaths has no effect under backend =
            "container": it adds to the native unit's ReadWritePaths, and
            the containerized client's write access is decided by its
            volume mappings instead. Unset it, or switch backend to
            "native".
          '';
        }
        {
          # Pointing user at an account that already exists as a normal
          # login user, with createUser left at its default of true, makes
          # this module declare that account a *system* user too, and
          # NixOS rejects the combination with "Exactly one of
          # isNormalUser and isSystemUser must be set" - an error that says
          # nothing about which option caused it or how to fix it. Catch it
          # here instead, where the fix can be named.
          #
          # createUser cannot simply default to "false when the account
          # already exists": that default would read config.users.users,
          # which this module also defines under a condition derived from
          # createUser, and the evaluation would cycle.
          assertion = !(cfg.enable && cfg.backend == "native" && cfg.createUser
            && cfg.user != "root"
            && (config.users.users ? ${cfg.user})
            && config.users.users.${cfg.user}.isNormalUser);
          message = ''
            services.idrive.user is "${cfg.user}", which is already defined
            as a normal login user, but services.idrive.createUser is still
            true, so this module would additionally declare it a system
            user and evaluation would fail.

            Set services.idrive.createUser = false to run the service as
            that existing account. createUser is only for accounts this
            module should bring into existence itself.
          '';
        }
      ];
      warnings = lib.optionals ((cfg.enable || cfg.userServices != [ ]) && !cfg.acceptTerms) [
        ''
          services.idrive will not do any work: services.idrive.acceptTerms
          is false, so no IDrive service, launcher or container is created.
          Read https://www.idrive.com/terms-and-conditions and set
          services.idrive.acceptTerms = true to accept them.
        ''
      ] ++ lib.optionals (cfg.acceptTerms && (cfg.userServices != [ ]
        || (cfg.enable && cfg.backend == "native" && cfg.user != "root"
            && !cfg.scheduledBackup.enable))) [
        ''
          services.idrive: no scheduled backups will run. The client's
          scheduler exits at once for any user but root, so a non-root
          services.idrive.user and every entry in userServices report success
          and do nothing. Use user = "root" or scheduledBackup.enable.
        ''
      ] ++ lib.optionals (cfg.enable && cfg.backend == "native" && cfg.readAllFiles && cfg.user == "root") [
        ''
          services.idrive.readAllFiles is true but services.idrive.user is
          "root", which can already read everything, so this option has no
          effect. This is harmless, just redundant.
        ''
      ];
    }
    (mkIf (cfg.enable && cfg.acceptTerms && cfg.backend == "native") {
    # hiPrio on the launcher, and both entries rather than just one: the
    # launcher owns bin/idrive (the documented `sudo idrive
    # --account-setting` entry point, which only works when it runs through
    # the writable application directory), while the package still supplies
    # the idevsutil* transfer utilities. Without hiPrio the two collide on
    # bin/idrive and the environment build fails.
    #
    # Run interactive setup as the service user (root by default), the same
    # user the unit runs as: whoever runs the launcher first owns the files
    # it creates under stateDir.
    environment.systemPackages = [ (lib.hiPrio namedLauncher) cfg.package ]
      ++ lib.optional restricted restrictedLauncher;

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} -"
    ] ++ lib.optionals cfg.legacySourceLinks sourceLinks;

    # Never touch users.users.root / users.groups.root: root always exists,
    # and defining it here would fight whatever the rest of the system
    # already says about it.
    # supplementaryGroups is also given to the account itself, not only to
    # the unit. SupplementaryGroups on the unit sets the daemon process's
    # supplementary GIDs directly and never touches /etc/group, so it does
    # nothing for the documented interactive path, which runs the launcher
    # outside systemd (sudo -u <user> idrive --account-setting). Without
    # this, setup and the daemon would see different files: setup could
    # fail to read a backup path the daemon reads fine, which is a
    # confusing thing to debug. Only possible when this module owns the
    # account; with createUser = false the unit-level grant still applies
    # to the daemon and the operator owns the group membership.
    users.users = lib.mkIf (cfg.createUser && cfg.user != "root") {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        extraGroups = cfg.supplementaryGroups;
      };
    };

    users.groups = lib.mkIf (cfg.createUser && cfg.user != "root" && cfg.group != "root") {
      ${cfg.group} = { };
    };

    # First-run setup, when credentials were supplied. Ordered before the
    # service and required by it, so the daemon never starts against a
    # profile that setup failed to create.
    systemd.services.idrive-setup = mkIf automaticSetup {
      description = "IDrive first-run account setup";
      before = [ "idrive.service" ];
      requiredBy = [ "idrive.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # It runs once and leaves a stamp. A profile that was linked some
      # other way is left alone: the driver declines the client's offer to
      # reconfigure it.
      unitConfig.ConditionPathExists = "!${cfg.stateDir}/.setup-done";

      environment = {
        TZ = cfg.timeZone;
        LC_ALL = "en_US.UTF-8";
      } // lib.optionalAttrs (cfg.deviceName != null) {
        IDRIVE_DEVICE_NAME = cfg.deviceName;
      } // lib.optionalAttrs restricted {
        HOME = cfg.stateDir;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = "${prepare}/bin/idrive-prepare";
        ExecStart = "${setup}/bin/idrive-setup";
      } // lib.optionalAttrs (cfg.supplementaryGroups != [ ]) {
        SupplementaryGroups = cfg.supplementaryGroups;
      } // lib.optionalAttrs restricted (clientSandbox // rootSandbox);
    };

    # Setup that failed on the network tries again without a reboot. A timer
    # rather than Restart=: a restarting oneshot stays activating, which would
    # hold multi-user.target until the network returned. The driver writes the
    # marker only for network failures, so a rejected password is never resent
    # from here.
    systemd.services.idrive-setup-retry = mkIf automaticSetup {
      description = "Retry IDrive account setup after a network failure";
      unitConfig.ConditionPathExists = [
        "${cfg.stateDir}/.setup-retry"
        "!${cfg.stateDir}/.setup-done"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl start --no-block idrive.service";
      };
    };
    systemd.timers.idrive-setup-retry = mkIf automaticSetup {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "*:0/5";
    };

    systemd.services.idrive = {
      description = "IDrive Linux backup client";
      wantedBy = [ "multi-user.target" ];
      # Wants, not Requires: Requires= would fail the unit whenever a disk is
      # absent, which is the failure the - prefixes below exist to avoid.
      unitConfig.WantsMountsFor = cfg.backupPaths ++ cfg.writablePaths;
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        TZ = cfg.timeZone;
        LC_ALL = "en_US.UTF-8";
      } // lib.optionalAttrs (cfg.deviceName != null) {
        # ExecStart runs the prepared application copy directly rather than
        # going through the launcher, so the launcher's own wrapper does not
        # cover the daemon. The wrapper's shims read this at runtime.
        IDRIVE_DEVICE_NAME = cfg.deviceName;
      } // lib.optionalAttrs restricted {
        HOME = cfg.stateDir;
      };

      serviceConfig = {
        Type = "simple";
        # The scheduler exits 0 whenever the clock jumps by more than 70
        # seconds, as after a suspend, expecting a distro service template to
        # bring it back. NixOS has none, so on-failure would leave it dead. As
        # any user but root it exits at once, so always would only loop.
        Restart = if cfg.user == "root" then "always" else "on-failure";
        RestartSec = 10;
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = [ "+${cronLockSetup}" "${prepare}/bin/idrive-prepare" ];
        # The daemon runs with or without a linked account. After setup
        # finishes it needs a `systemctl restart idrive` to pick the account
        # up. As any user but root the client's scheduler exits 0 at once,
        # see the warning above.
        # Not "${launcher}/bin/idrive --cron": the launcher runs the prepare
        # step itself, and under Type=simple systemd considers the service
        # started the moment ExecStart is forked, so preparing from there
        # would let "systemctl start idrive" return while the state
        # directory is still being seeded. Keeping the prepare step in
        # ExecStartPre preserves systemd's own ordering guarantee, and
        # leaves ExecStart as exactly what the launcher would have exec'd:
        # the idrivecron symlink in the prepared application directory,
        # which is what makes the client's appPath resolve to a writable
        # directory and satisfies its "--cron only through a symlink"
        # guard (see nix/start.nix).
        ExecStart = "${cfg.stateDir}/${startLib.appSubdir}/idrivecron --cron";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        # ReadWritePaths takes priority over ProtectSystem and ProtectHome
        # above, so this is what reopens a restore target for writing
        # without relaxing either of them globally.
        #
        # The - makes an absent path harmless. Without it one unplugged disk
        # fails the whole unit with 226/NAMESPACE and stops every backup.
        ReadWritePaths = [ cfg.stateDir ] ++ map (p: "-${p}") cfg.writablePaths;
        # ReadOnlyPaths only marks these paths read-only inside the unit's
        # mount namespace; it grants no DAC access by itself. What actually
        # lets a non-root user read files under these paths is group
        # ownership through SupplementaryGroups, or readAllFiles. An ACL does
        # not: see the README's permission model section.
        ReadOnlyPaths = map (p: "-${p}") cfg.backupPaths;
      }
      // lib.optionalAttrs (cfg.supplementaryGroups != [ ]) {
        SupplementaryGroups = cfg.supplementaryGroups;
      }
      // lib.optionalAttrs restricted rootSandbox
      // lib.optionalAttrs (cfg.umask != null) {
        UMask = cfg.umask;
      }
      # StateDirectory is always relative to /var/lib, so it only applies
      # when stateDir keeps its default. A custom path is handled by the
      # tmpfiles rule above plus ReadWritePaths. StateDirectoryMode is set
      # explicitly because StateDirectory otherwise carries systemd's own
      # 0755 default, which systemd reconciles at unit start regardless of
      # what the tmpfiles rule above asked for - systemd wins that
      # disagreement, and this directory holds user_profile, which contains
      # account credentials.
      // lib.optionalAttrs usesDefaultStateDir {
        StateDirectory = "idrive";
        StateDirectoryMode = "0700";
      };
    };
    })
    (mkIf (cfg.enable && cfg.acceptTerms) {
      environment.systemPackages = [ permissionTools ];
    })
    (mkIf (cfg.enable && cfg.acceptTerms && useView) {
      # The only root part of a non-root setup. The mounts have to appear in
      # the host's namespace, which rules out most sandboxing, so it gets no
      # network and no capabilities beyond these.
      # --force-user makes every file the service user's, which is how `-r`
      # passes; the parent directory is what keeps everyone else out.
      systemd.services.idrive-read-view = {
        description = "Read-only view of the IDrive backup paths";
        unitConfig.WantsMountsFor = cfg.backupPaths;
        path = [ pkgs.bindfs pkgs.coreutils pkgs.fuse3 pkgs.util-linux ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Not PrivateNetwork: that needs a mount namespace, and the view has
          # to land in the host's.
          IPAddressDeny = "any";
          RestrictAddressFamilies = [ "AF_UNIX" ];
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "CAP_SYS_ADMIN" "CAP_DAC_READ_SEARCH" ];
        };
        script = ''
          install -d -m 0700 ${viewRoot}
          for path in ${lib.escapeShellArgs cfg.backupPaths}; do
            target=${viewRoot}$path
            mountpoint -q "$target" && continue
            if [ ! -e "$path" ]; then
              echo "idrive-read-view: $path is missing, skipped" >&2
              continue
            fi
            mkdir -p "$target"
            bindfs -o ro,allow_other \
              --force-user=${lib.escapeShellArg cfg.user} --force-group=${lib.escapeShellArg cfg.group} \
              --perms=u+rX,go-rwx "$path" "$target"
          done
        '';
        preStop = ''
          for path in ${lib.escapeShellArgs cfg.backupPaths}; do
            umount -l ${viewRoot}"$path" || true
          done
        '';
      };
    })
    (mkIf (cfg.enable && cfg.acceptTerms && cfg.scheduledBackup.enable) {
      systemd.services.idrive-backup = lib.recursiveUpdate jobUnit {
        description = "IDrive backup";
        after = [ "network-online.target" "idrive-setup.service" ]
          ++ lib.optional (cfg.user != "root") "idrive-watcher.service"
          ++ lib.optional useView "idrive-read-view.service"
          ++ lib.optional (cfg.permissionManifest.paths != [ ]) "idrive-permission-manifest.service";
        wants = [ "network-online.target" ]
          ++ lib.optional (cfg.user != "root") "idrive-watcher.service"
          ++ lib.optional (cfg.permissionManifest.paths != [ ]) "idrive-permission-manifest.service";
        requires = lib.optional useView "idrive-read-view.service";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${backupJob}/bin/idrive-backup-job";
          TimeoutStartSec = cfg.scheduledBackup.timeout;
        };
      };

      systemd.timers.idrive-backup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.scheduledBackup.schedule;
          Persistent = true;
        };
      };

      # As root the daemon starts this itself. Without it a non-root backup can
      # miss changes and still report success.
      systemd.services.idrive-watcher = mkIf (cfg.user != "root") (lib.recursiveUpdate jobUnit {
        description = "IDrive change watcher";
        wantedBy = [ "multi-user.target" ];
        after = [ "idrive-setup.service" ] ++ lib.optional useView "idrive-read-view.service";
        bindsTo = lib.optional useView "idrive-read-view.service";
        unitConfig.ConditionPathExistsGlob =
          "${cfg.stateDir}/user_profile/${cfg.user}/*/CONFIGURATION_FILE";
        serviceConfig = {
          ExecStart = "${namedLauncher}/bin/idrive --utilities --watcher-service";
          Restart = "on-failure";
          RestartSec = 30;
        };
      });
    })
    (mkIf (cfg.enable && cfg.acceptTerms && cfg.permissionManifest.paths != [ ]) {
      systemd.services.idrive-permission-manifest = {
        description = "Record file permissions for IDrive restores";
        serviceConfig = {
          Type = "oneshot";
          # Root because it has to read every file's metadata and write into
          # each tree. The records go to the service user, who backs them up.
          ExecStart = lib.escapeShellArgs ([
            "${permissionTools}/bin/idrive-save-permissions"
            "--owner"
            "${cfg.user}:${cfg.group}"
          ] ++ cfg.permissionManifest.paths);
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };

      systemd.timers.idrive-permission-manifest = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.permissionManifest.schedule;
          Persistent = true;
        };
      };
    })
    (mkIf (cfg.enable && cfg.acceptTerms && cfg.backend == "container") {
      virtualisation.oci-containers = {
        backend = cfg.container.runtime;
        containers.idrive = {
          inherit (cfg.container) image imageFile;
          autoStart = true;
          environment = {
            TZ = cfg.timeZone;
          };
          # Reproduces the upstream image's own address scheme exactly:
          # stateDir at the container's fixed idriveIt path, and each
          # backupPaths entry at /source/N:ro, numbered from 1. Existing
          # backup sets are configured against those exact paths, so this
          # ordering and numbering must not change.
          volumes = [
            "${cfg.stateDir}:/opt/IDriveForLinux/idriveIt"
          ] ++ lib.imap1
            (i: path: "${path}:/source/${toString i}:ro")
            cfg.backupPaths;
        };
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.stateDir} 0700 root root -"
      ];
    })

    # Per-user services. Independent of services.idrive.enable and of
    # backend: this is a different shape of deployment (one account per
    # person) rather than a variant of the system-wide one, and a machine
    # can legitimately run both.
    (mkIf (cfg.acceptTerms && cfg.userServices != [ ]) {
      environment.systemPackages = [ namedUserLauncher ];

      # Without lingering, a user's systemd manager exits when their last
      # session ends, taking the backup service with it. A backup that only
      # runs while you are logged in is not one you would want to find out
      # about during a restore.
      users.users = lib.genAttrs cfg.userServices (_: { linger = true; });

      systemd.user.services.idrive = {
        description = "IDrive backup client (per-user)";
        wantedBy = [ "default.target" ];

        # systemd.user units are defined for every user on the machine, so
        # the unit itself has to decide who it runs for.
        #
        # The pipe prefix is load-bearing. From systemd.unit(5): "If
        # multiple conditions are specified, the unit will be executed if
        # all of them apply (i.e. a logical AND is applied)", and a pipe
        # after the equals sign makes a condition "triggering", where "the
        # unit will be started if at least one of the triggering conditions
        # of the unit applies". Plain ConditionUser= lines would therefore
        # AND together, no user would be all of the listed users at once,
        # and the service would silently never start for anybody.
        unitConfig.ConditionUser = map (u: "|${u}") cfg.userServices;

        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = 10;
          ExecStart = "${namedUserLauncher}/bin/idrive-user --cron";
        };

        environment = {
          TZ = cfg.timeZone;
          LC_ALL = "en_US.UTF-8";
        };
      };
    })
  ];
}
