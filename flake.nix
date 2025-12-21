{
  description = "httpg";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs";
    devenv.url = "github:cachix/devenv";
    crane.url = "github:ipetkov/crane";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = inputs@{ flake-parts, crane, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.devenv.flakeModule
      ];
      systems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      perSystem = { config, self', inputs', pkgs, system, ... }: let
        n2c = inputs.nix2container.packages.x86_64-linux;
        craneLib = crane.mkLib pkgs;
        crate = {
          src = craneLib.cleanCargoSource ./.;

          doCheck = false;

          nativeBuildInputs = with pkgs; [
            mold-wrapped clang pkg-config openssl.dev
          ];
          buildInputs = with pkgs; [
            pkg-config openssl.dev
          ];
          env = {
            RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
          };
        };
      in {

        packages.httpg-dev = craneLib.buildPackage (crate // { CARGO_PROFILE = "dev"; });
        packages.httpg = craneLib.buildPackage (crate // { CARGO_PROFILE = "release"; });

        packages.default = self'.packages.httpg;

        packages.oci = n2c.nix2container.buildImage {
          name = "docteurklein/httpg";
          config = {
            entrypoint = ["${self'.packages.httpg}/bin/httpg"];
          };
          copyToRoot = pkgs.buildEnv {
            name = "assets";
            paths = with pkgs.dockerTools; [
              ./.
              binSh
              caCertificates
            ];
            pathsToLink = ["/public" "/" "/etc"];
          };
        };

        devenv.shells.default = {
          name = "httpg";

          imports = [
          ];

          # https://devenv.sh/reference/options/
          packages = with pkgs; [
            postgresql_18
            cargo cargo-watch cargo-shear clippy rustc rust-analyzer openssl.dev pkg-config
            mold-wrapped clang
            biscuit-cli
          ];

          env = {
            PG_DBNAME = "httpg";
            PG_USER = "httpg";
            HTTPG_LOGIN_QUERY="select login()";
            HTTPG_PRIVATE_KEY = "private-key-file";
            HTTPG_ANON_ROLE = "person";
            HTTPG_INDEX_SQL = "table head union all table findings";
            RUST_LOG = "tokio_postgres=debug,httpg=debug,axum=debug";
          };
          
          processes.postgres.process-compose.readiness_probe.exec.command = with pkgs.lib; mkForce "true"; #"pg_isready -d template1";

          services.postgres = {
            enable = true;
            package = pkgs.postgresql_18;
            initialDatabases = [{
              name = "httpg";
            }];
            extensions = extensions: with extensions; [
              # self'.packages.pg_render
              plv8
              # pg_net
              pgsql-http
              pgvector
              pg_cron
            ];
            settings = {
              # "wal_level" = "logical";
              # "app.tenant" = "tenant#1";
              "cron.database_name" = "httpg";
              shared_preload_libraries = "auto_explain, pg_cron";
              "auto_explain.log_min_duration" = "0ms";
              # "auto_explain.log_nested_statements" = true;
              "auto_explain.log_timing" = true;
              "auto_explain.log_analyze" = true;
              "auto_explain.log_buffers" = true;
              "auto_explain.log_settings" = true;
              # "auto_explain.log_format" = "json";
              "auto_explain.log_triggers" = true;
              log_statement = "all";
              log_filename = "postgresql.log";
              log_destination = "stderr";
              logging_collector = true;
              log_connections = true;
              log_disconnections = true;
              lc_messages = "en_US.UTF-8";
            };
          };
        };
      };
    };
}

