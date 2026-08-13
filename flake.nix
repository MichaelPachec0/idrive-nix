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
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # 3.8.0 is amd64-only: it is extracted from a published image layer
          # that only exists for that architecture, see
          # nix/package-from-image.nix for why there is no vendor .bin to
          # build it from instead.
          idrive-client_3_8_0 = pkgs.callPackage ./nix/package-from-image.nix { };
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
          prepare-script = pkgs.callPackage ./nix/tests/prepare-script.nix {
            inherit idrive-client;
          };
          prepare-script-bad-timezone = pkgs.callPackage ./nix/tests/prepare-script-bad-timezone.nix {
            inherit idrive-client;
          };
          prepare-script-version-gate = pkgs.callPackage ./nix/tests/prepare-script-version-gate.nix {
            inherit idrive-client;
          };
          native = pkgs.callPackage ./nix/tests/native.nix {
            nixosModule = self.nixosModules.idrive;
            inherit idrive-client;
          };
          image = pkgs.callPackage ./nix/tests/image.nix {
            idrive-image = self.packages.${system}.idrive-image;
          };
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # idrive-client_3_8_0 only exists for x86_64-linux; see the same
          # guard on the package itself in the packages output above.
          package-layout-380 = pkgs.callPackage ./nix/tests/package-layout.nix {
            idrive-client = self.packages.${system}.idrive-client_3_8_0;
          };
          package-runs-380 = pkgs.callPackage ./nix/tests/package-runs.nix {
            idrive-client = self.packages.${system}.idrive-client_3_8_0;
          };
          package-no-selfupdate-380 = pkgs.callPackage ./nix/tests/package-no-selfupdate.nix {
            idrive-client = self.packages.${system}.idrive-client_3_8_0;
          };
          package-cron-guard-380 = pkgs.callPackage ./nix/tests/package-cron-guard.nix {
            idrive-client = self.packages.${system}.idrive-client_3_8_0;
          };
        });
    };
}
