{
  description = "pgpim";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs";
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

        packages.pg_render = pkgs.buildPgrxExtension rec {
          pname = "pg_render";
          version = "0.1";
          inherit system;
          postgresql = pkgs.postgresql_17;

          src = pkgs.fetchFromGitHub {
            owner = "mkaski";
            repo = pname;
            rev = "master";
            hash = "sha256-idnkh91kdsnXiF79q7SN9yOJM1eVLsIS35FFXiyOpS4=";
          };
          cargoHash = "sha256-q5Rv2G+deh7uHiKZSS0SgF4KiAqB3kxeub6czXBsuaI=";
          cargoPatches = [
            ./add-cargo.patch
          ];
        };

        devenv.shells.default = {
          name = "httpg";

          imports = [
          ];

          # https://devenv.sh/reference/options/
          packages = with pkgs; [
            postgresql_17
            cargo cargo-watch clippy rustc rust-analyzer openssl.dev pkg-config
            mold clang
            biscuit-cli
          ];

          services.postgres = {
            enable = true;
            package = pkgs.postgresql_17;
            initialDatabases = [{
              name = "httpg";
            }];
            extensions = extensions: [
              # self'.packages.pg_render
              extensions.plv8
            ];
            settings = {
              # "wal_level" = "logical";
              "app.tenant" = "tenant#1";
              "shared_preload_libraries" = "auto_explain";
              "auto_explain.log_min_duration" = "0ms";
              "auto_explain.log_nested_statements" = true;
              "auto_explain.log_timing" = true;
              "auto_explain.log_analyze" = true;
              "auto_explain.log_triggers" = true;
            };
          };
        };
      };
    };
}

