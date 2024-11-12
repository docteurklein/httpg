{
  description = "pgpim";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.devenv.flakeModule
      ];
      systems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      perSystem = { config, self', inputs', pkgs, system, ... }: {

        packages.pg_render = pkgs.stdenv.mkDerivation rec {
          pname = "pg_render";
          version = "0.1";

          src = pkgs.fetchFromGitHub {
            owner = "mkaski";
            repo = pname;
            # url = "https://github.com/mkaski/pg_render.git";
            rev = "master";
            hash = "sha256-idnkh91kdsnXiF79q7SN9yOJM1eVLsIS35FFXiyOpS4=";
            # deepClone = true;
            # fetchSubmodules = true;
            # leaveDotGit = true;
          };
          # doCheck = false;
          # doBuild = false;

          buildInputs = with pkgs; [ postgresql_16 cargo cargo-pgrx ];

          # patches = [ ./patch_nix ];

          # dontConfigure = true;
          buildPhase = ''
            cargo pgrx package
          '';
          installPhase = ''
            ls -alh .
            # touch $out
          '';
        };
        devenv.shells.default = {
          name = "httpg";

          imports = [
          ];

          # https://devenv.sh/reference/options/
          packages = with pkgs; [
            postgresql_16
            cargo rustc rust-analyzer openssl.dev pkg-config
          ];

          services.postgres = {
            enable = true;
            package = pkgs.postgresql_16;
            initialDatabases = [{
              name = "httpg";
            }];
            extensions = extensions: [
              # self'.packages.pg_render
            ];
            settings = {
            };
          };
        };
      };
    };
}

