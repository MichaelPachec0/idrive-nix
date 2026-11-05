{
  description = "iDrive Linux client: Nix package, NixOS module, and OCI image";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      overlays.default = final: prev: {
        idrive-client = final.callPackage ./nix/package.nix { };
      };

      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          idrive-client = pkgs.callPackage ./nix/package.nix { };
        in
        {
          inherit idrive-client;
          idrive-image = pkgs.callPackage ./nix/image.nix { inherit idrive-client; };
          default = idrive-client;
        });

      nixosModules.idrive = import ./nix/module.nix;

      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          update = pkgs.writeShellApplication {
            name = "idrive-update";
            runtimeInputs = with pkgs; [ curl jq gnused gnugrep coreutils nix git ];
            text = builtins.readFile ./nix/update.sh;
          };
        in
        {
          update = { type = "app"; program = "${update}/bin/idrive-update"; };
        });

      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          idrive-client = self.packages.${system}.idrive-client;
        in
        {
          package-layout = pkgs.callPackage ./nix/tests/package-layout.nix {
            inherit idrive-client;
          };
          package-runs = pkgs.callPackage ./nix/tests/package-runs.nix {
            inherit idrive-client;
          };
          package-no-selfupdate = pkgs.callPackage ./nix/tests/package-no-selfupdate.nix {
            inherit idrive-client;
          };
          package-cron-guard = pkgs.callPackage ./nix/tests/package-cron-guard.nix {
            inherit idrive-client;
          };
          wrapper-shellcheck = pkgs.callPackage ./nix/tests/wrapper-shellcheck.nix {
            inherit idrive-client;
          };
          client-uses-statedir = pkgs.callPackage ./nix/tests/client-uses-statedir.nix {
            inherit idrive-client;
          };
          prepare-script = pkgs.callPackage ./nix/tests/prepare-script.nix {
            inherit idrive-client;
          };
          prepare-script-bad-timezone = pkgs.callPackage ./nix/tests/prepare-script-bad-timezone.nix {
            inherit idrive-client;
          };
          prepare-script-version-gate = pkgs.callPackage ./nix/tests/prepare-script-version-gate.nix {
            inherit idrive-client;
          };
          setup-driver = pkgs.callPackage ./nix/tests/setup-driver.nix { };
          terms-gate = pkgs.callPackage ./nix/tests/terms-gate.nix {
            nixosModule = self.nixosModules.idrive;
            inherit idrive-client;
          };
          native = pkgs.callPackage ./nix/tests/native.nix {
            nixosModule = self.nixosModules.idrive;
            inherit idrive-client;
          };
          permissions = pkgs.callPackage ./nix/tests/permissions.nix {
            nixosModule = self.nixosModules.idrive;
            inherit idrive-client;
          };
          setup-credentials = pkgs.callPackage ./nix/tests/setup-credentials.nix {
            nixosModule = self.nixosModules.idrive;
            inherit idrive-client;
          };
          user-service = pkgs.callPackage ./nix/tests/user-service.nix {
            nixosModule = self.nixosModules.idrive;
            inherit idrive-client;
          };
          image = pkgs.callPackage ./nix/tests/image.nix {
            idrive-image = self.packages.${system}.idrive-image;
          };
          container = pkgs.callPackage ./nix/tests/container.nix {
            nixosModule = self.nixosModules.idrive;
            inherit idrive-client;
            idrive-image = self.packages.${system}.idrive-image;
          };
        });
    };
}
