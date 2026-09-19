{
  description = "Windscribe VPN client (desktop GUI and CLI) packaged for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      overlays.default = final: _prev: {
        windscribe = final.callPackage ./pkgs/windscribe { };
        windscribe-cli = final.callPackage ./pkgs/windscribe { variant = "cli"; };
      };
      overlays.windscribe = self.overlays.default;

      packages = forAllSystems (
        { pkgs, ... }:
        rec {
          windscribe = pkgs.callPackage ./pkgs/windscribe { };
          windscribe-cli = pkgs.callPackage ./pkgs/windscribe { variant = "cli"; };
          default = windscribe;
        }
      );

      nixosModules.windscribe = import ./modules/nixos.nix;
      nixosModules.default = self.nixosModules.windscribe;

      homeManagerModules.windscribe = import ./modules/home-manager.nix;
      homeManagerModules.default = self.homeManagerModules.windscribe;

      checks = forAllSystems (
        { pkgs, system }:
        {
          package-gui = self.packages.${system}.windscribe;
          package-cli = self.packages.${system}.windscribe-cli;
        }
        # The VM tests need a KVM-capable builder of the same architecture.
        // lib.optionalAttrs (system == "x86_64-linux") {
          vm-gui = pkgs.testers.runNixOSTest (
            import ./tests/vm.nix {
              inherit self;
              variant = "gui";
            }
          );
          vm-cli = pkgs.testers.runNixOSTest (
            import ./tests/vm.nix {
              inherit self;
              variant = "cli";
            }
          );
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              curl
              dpkg
              jq
              nix-prefetch
              nixfmt
              patchelf
              upx
            ];
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt);
    };
}
