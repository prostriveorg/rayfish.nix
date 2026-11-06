{
  description = "Rayfish — P2P mesh VPN powered by iroh";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rayfish-src = {
      url = "github:rayfish/rayfish/v0.5.16";
      flake = false;
    };
    # The iroh fork Rayfish pins in Cargo.toml. Used only by the end-to-end
    # test's local relay server.
    iroh-src = {
      url = "github:rayfish/iroh/9dab676bb935caeddde67af273fcdc7d61daf6fc";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, rayfish-src, iroh-src }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      gitSha = self.shortRev or self.dirtyShortRev or "unknown";
    in
    {
      overlays.default = final: _prev: {
        rayfish = final.callPackage ./nix/package.nix { src = rayfish-src; inherit gitSha; };
      };

      packages = eachSystem (pkgs: rec {
        rayfish = pkgs.callPackage ./nix/package.nix { src = rayfish-src; inherit gitSha; };
        default = rayfish;
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            rustc
            clippy
            rustfmt
            rust-analyzer
            just
          ];
        };
      });

      # nix/module.nix is flake-free on purpose; this wrapper defaults the
      # package to the flake's build so consumers do not need the overlay.
      nixosModules.rayfish =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          services.rayfish.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.rayfish;
        };
      nixosModules.default = self.nixosModules.rayfish;

      checks = eachSystem (
        pkgs:
        {
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.rayfish;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          vm-test = pkgs.testers.runNixOSTest (
            import ./nix/vm-test.nix { rayfishModule = self.nixosModules.rayfish; }
          );
          vm-test-e2e = pkgs.testers.runNixOSTest (
            import ./nix/vm-test-e2e.nix {
              inherit pkgs;
              irohSrc = iroh-src;
              rayfishModule = self.nixosModules.rayfish;
            }
          );
        }
      );
    };
}
