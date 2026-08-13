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

      checks = forAllSystems (system: { });
    };
}
