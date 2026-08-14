{ config, lib, pkgs, ... }:

let
  cfg = config.services.idrive;
  inherit (lib) mkIf mkOption mkEnableOption mkPackageOption types;

  startLib = pkgs.callPackage ./start.nix { idrive-client = cfg.package; };
  prepare = startLib.mkPrepare {
    inherit (cfg) stateDir timeZone;
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
        This module does not create that user: set users.users.<name>
        yourself before pointing this option at it. Under backend =
        "container" the client runs as whatever user is baked into the
        image (root), not a host user this module could substitute in;
        setting user away from its default there has no effect and fails
        evaluation.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = ''
        Applies only to backend = "native": group the service runs as.
        Under backend = "container" this has no effect, for the same
        reason as user above, and fails evaluation if set away from its
        default there.
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
      ];
    }
    (mkIf (cfg.enable && cfg.backend == "native") {
    environment.systemPackages = [ cfg.package ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} -"
    ] ++ lib.optionals cfg.legacySourceLinks sourceLinks;

    systemd.services.idrive = {
      description = "IDrive Linux backup client";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        TZ = cfg.timeZone;
        LC_ALL = "en_US.UTF-8";
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
        ExecStart = "${cfg.package}/bin/idrive --cron";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        ReadWritePaths = [ cfg.stateDir ];
        ReadOnlyPaths = cfg.backupPaths;
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
  ];
}
