{ pkgs, lib, nixosModule, idrive-client }:

# Evaluation only: whether acceptTerms gates the module is a property of the
# generated configuration, so no VM is needed to prove it.
let
  evalWith = settings: (pkgs.nixos ({ ... }: {
    imports = [ nixosModule ];
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    system.stateVersion = "26.05";
    users.users.alice = { isNormalUser = true; };
    services.idrive = { package = idrive-client; timeZone = "Etc/UTC"; } // settings;
  })).config;

  warned = config: lib.any (lib.hasInfix "will not do any work") config.warnings;
  createdAnything = config:
    config.systemd.services ? idrive
    || config.systemd.services ? idrive-setup
    || config.systemd.user.services ? idrive
    || config.virtualisation.oci-containers.containers ? idrive;

  native = { enable = true; };
  container = { enable = true; backend = "container"; };
  perUser = { userServices = [ "alice" ]; };
  withSetup = {
    enable = true;
    username = "someone@example.invalid";
    passwordFile = "/run/idrive-password";
  };

  refused = lib.all (s: let c = evalWith s; in warned c && !createdAnything c)
    [ native container perUser withSetup ];
  accepted = lib.all (s:
    let c = evalWith (s // { acceptTerms = true; }); in !warned c && createdAnything c)
    [ native container perUser withSetup ];
  # Nothing asked for, nothing to warn about.
  quiet = !warned (evalWith { });
in
assert lib.assertMsg refused "without acceptTerms the module must warn and create nothing";
assert lib.assertMsg accepted "with acceptTerms the module must create its units and not warn";
assert lib.assertMsg quiet "a host that does not use the module must not be warned";
pkgs.runCommand "idrive-terms-gate" { } "touch $out"
