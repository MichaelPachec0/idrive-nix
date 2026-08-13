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
in
{
  options.services.idrive = {
    enable = mkEnableOption "the IDrive Linux backup client";

    package = mkPackageOption pkgs "idrive-client" { };

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
        A backup agent can only read what its user can read. root is the
        default for whole-system backups; a dedicated user is safer when the
        backup set is narrow.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = "Group the service runs as.";
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
        Create /source/N symlinks to backupPaths, matching the container
        layout, so backup sets configured against the Docker image keep
        working after migrating to the native backend.
      '';
    };

    dumpDir = mkOption {
      type = types.path;
      default = "${cfg.stateDir}/CDPDBDUMP";
      description = ''
        Where the client writes its CDP database dumps. Separated out because
        unbounded growth here has been reported to fill disks.
      '';
    };
  };

  config = mkIf (cfg.enable && cfg.backend == "native") {
    environment.systemPackages = [ cfg.package ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dumpDir} 0700 ${cfg.user} ${cfg.group} -"
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
        ExecStart = "${cfg.package}/bin/idrive --cron";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
        ReadWritePaths = [ cfg.stateDir cfg.dumpDir ];
        ReadOnlyPaths = cfg.backupPaths;
      }
      # StateDirectory is always relative to /var/lib, so it only applies
      # when stateDir keeps its default. A custom path is handled by the
      # tmpfiles rule above plus ReadWritePaths.
      // lib.optionalAttrs usesDefaultStateDir { StateDirectory = "idrive"; };
    };
  };
}
