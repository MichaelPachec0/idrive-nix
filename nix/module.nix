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

  automaticSetup = cfg.username != null && cfg.passwordFile != null;

  setup = startLib.mkSetup {
    stateExpr = ''"${cfg.stateDir}"'';
    launcher = namedLauncher;
    launcherBin = "idrive";
    inherit (cfg) username passwordFile;
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
        For data that is not already group-readable, see readAllFiles
        below.

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
        Applies only to backend = "native". When true, grants the service
        the CAP_DAC_READ_SEARCH capability (via both AmbientCapabilities
        and CapabilityBoundingSet), which lets it read every file and
        search every directory on the system regardless of ownership or
        mode, bypassing normal DAC read/search checks entirely. This is a
        real privilege grant: with it, the service can read any file a
        root process could read. It is narrower than running as root only
        in that it grants no write, execute, or other capability, so a
        compromised or malicious client still cannot modify, delete, or
        execute anything outside what user/group/supplementaryGroups
        already allow. It also does not guarantee access: mandatory access
        control (SELinux, AppArmor) or a filesystem that denies the
        capability outright can still block a read. Prefer
        supplementaryGroups or a default ACL (see the README) when either
        one covers the backup set; reach for this only when the set is
        broad or unpredictable enough that neither is practical.
      '';
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
      description = "Paths made available to the client for backup.";
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

    passwordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/idrive-password";
      description = ''
        File holding the password for username, read at setup time and
        never copied anywhere. Point this at a secret your secret manager
        decrypts at activation (sops-nix, agenix, or a systemd credential),
        not at a file in the Nix store: everything in the store is
        world-readable.

        The file should be mode 0400 and owned by services.idrive.user. Its
        contents are the password and nothing else; trailing whitespace is
        stripped, an empty file is an error.

        The password reaches the client on standard input, so it never
        appears in the process table or in the unit's environment.

        This automates the setup the client otherwise prompts for. The
        client has no non-interactive login of its own, so the module
        answers its prompts in order, and that order is a property of the
        client rather than a documented interface. Setup runs once, checks
        that it worked, and fails loudly rather than leaving a
        half-configured profile behind.
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
            image's own root user, which already bypasses the checks this
            option would grant a capability around. Unset it, or switch
            backend to "native".
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
          assertion = (cfg.username == null) == (cfg.passwordFile == null);
          message = ''
            services.idrive.username and services.idrive.passwordFile go
            together: either set both, to have this module perform account
            setup, or neither, to do it interactively. Setting one alone
            would leave setup half specified and still waiting for a person.
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
      warnings = lib.optionals (cfg.enable && cfg.backend == "native" && cfg.readAllFiles && cfg.user == "root") [
        ''
          services.idrive.readAllFiles is true but services.idrive.user is
          "root": root already bypasses the DAC checks CAP_DAC_READ_SEARCH
          would otherwise get around, so this option has no additional
          effect. This is harmless, just redundant.
        ''
      ];
    }
    (mkIf (cfg.enable && cfg.backend == "native") {
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
    environment.systemPackages = [ (lib.hiPrio namedLauncher) cfg.package ];

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
    # profile that setup failed to create: a half-configured client that
    # exits cleanly would otherwise look exactly like a correctly
    # configured one with nothing to do.
    systemd.services.idrive-setup = mkIf automaticSetup {
      description = "IDrive first-run account setup";
      before = [ "idrive.service" ];
      requiredBy = [ "idrive.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # It runs once and leaves a stamp; the client itself is the other
      # guard, refusing to reconfigure an account that is already linked.
      unitConfig.ConditionPathExists = "!${cfg.stateDir}/.setup-done";

      environment = {
        TZ = cfg.timeZone;
        LC_ALL = "en_US.UTF-8";
      } // lib.optionalAttrs (cfg.deviceName != null) {
        IDRIVE_DEVICE_NAME = cfg.deviceName;
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
      };
    };

    systemd.services.idrive = {
      description = "IDrive Linux backup client";
      wantedBy = [ "multi-user.target" ];
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
      };

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 10;
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = "${prepare}/bin/idrive-prepare";
        # idrive --cron exits 0 immediately, before doing any sustained
        # work, until an IDrive account has been linked (a precondition
        # check inside the client itself, not a fault in this unit). On a
        # fresh deployment this unit therefore starts, exits cleanly, and
        # sits inactive; Restart=on-failure will not bring it back up after
        # the operator finishes account setup, since that exit is not a
        # failure. A manual `systemctl restart idrive` is required once
        # setup completes.
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
        ReadWritePaths = [ cfg.stateDir ] ++ cfg.writablePaths;
        # ReadOnlyPaths only marks these paths read-only inside the unit's
        # mount namespace; it grants no DAC access by itself. What actually
        # lets a non-root user read files under these paths is
        # SupplementaryGroups, readAllFiles below, or host-managed ACLs -
        # see the README's permission model section.
        ReadOnlyPaths = cfg.backupPaths;
      }
      // lib.optionalAttrs (cfg.supplementaryGroups != [ ]) {
        SupplementaryGroups = cfg.supplementaryGroups;
      }
      // lib.optionalAttrs cfg.readAllFiles {
        # CAP_DAC_READ_SEARCH bypasses file read and directory search
        # permission checks without granting any write capability - the
        # narrowest capability that gets a non-root backup agent "read
        # everything". Both AmbientCapabilities and CapabilityBoundingSet
        # are needed: AmbientCapabilities is what actually carries the
        # capability into the non-root process's effective set (a
        # non-root process's ambient set is otherwise always empty), and
        # CapabilityBoundingSet has to include it too, or the ambient grant
        # is dropped, since a capability cannot be ambient unless it is
        # also in the bounding set. This is compatible with
        # NoNewPrivileges=true above: unlike file capabilities or setuid,
        # ambient capabilities do not need privilege escalation at exec
        # time to take effect, and nix/tests/permissions.nix exercises this
        # combination directly rather than assuming it: it reads a 0600
        # root-owned file as the service user, and asserts the same read
        # fails without the capability.
        AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
      }
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
    (mkIf (cfg.enable && cfg.backend == "container") {
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
    (mkIf (cfg.userServices != [ ]) {
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
