{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    # build.zig.zon declares minimum_zig_version = 0.15.2; the code does not build on 0.16
    zigFor = pkgs: pkgs.zig_0_15;
  in {
    packages = forAllSystems (pkgs: {
      default = pkgs.stdenv.mkDerivation {
        pname = "zcpu";
        version = "0.0.1";
        src = self;
        nativeBuildInputs = [(zigFor pkgs).hook];
      };
    });

    apps = forAllSystems (pkgs: {
      default = {
        type = "app";
        program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/zcpu";
      };
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = [
          (zigFor pkgs)
          pkgs.zls # Zig language server
        ];
      };
    });
  };
}
