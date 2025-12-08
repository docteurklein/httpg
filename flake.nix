{
  description = "httpg";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs";
    devenv.url = "github:cachix/devenv";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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

      perSystem = { config, self', inputs', pkgs, system, ... }:
        let n2c = inputs.nix2container.packages.x86_64-linux;
      in {

        packages.pg_render = pkgs.buildPgrxExtension rec {
          pname = "pg_render";
          version = "0.1";
          inherit system;
          postgresql = pkgs.postgresql_18;

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

        # packages.pgrag = pkgs.buildPgrxExtension rec {
        #   pname = "pgrag";
        #   version = "0.1";
        #   inherit system;
        #   postgresql = pkgs.postgresql_18;
        #   cargo-pgrx = pkgs.cargo-pgrx;

        #   src = pkgs.fetchFromGitHub {
        #     owner = "neondatabase-labs";
        #     repo = pname;
        #     rev = "main";
        #     rootDir = "exts/rag_bge_small_en_v15";
        #     hash = "sha256-ioD0DrZZOgIFfc5FtunsbvthAJmkA+VvzGAuaaD+xBE=";
        #   };
        #   cargoHash = "sha256-Xcr4/BsxQrau5Qxgz7iw9d+j1wwYoObhKRRrtUQpAlI=";
        #   cargoPatches = [
        #     ./add-cargo-rag-bge.patch
        #   ];
        # };

        packages.httpg = pkgs.rustPlatform.buildRustPackage {
          pname = "httpg";
          version = "0.1";
          cargoLock.lockFile = ./Cargo.lock;
          src = pkgs.lib.cleanSource ./.;
          nativeBuildInputs = with pkgs; [
            mold-wrapped clang pkg-config openssl.dev
          ];
          buildInputs = with pkgs; [
            pkg-config openssl.dev
          ];
          env = {
            RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
          };
          doCheck = false;
        };

        packages.default = self'.packages.httpg;

        packages.oci = n2c.nix2container.buildImage {
          name = "docteurklein/httpg";
          config = {
            entrypoint = ["${self'.packages.httpg}/bin/httpg"];
          };
          copyToRoot = pkgs.buildEnv {
            name = "assets";
            paths = [ ./. ];
            pathsToLink = [ "/public" ];
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
            HTTPG_LOGIN_QUERY="select cpres.login()";
            HTTPG_PRIVATE_KEY = "private-key-file";
            HTTPG_ANON_ROLE = "person";
          };
          
          processes.postgres.process-compose.readiness_probe.exec.command = with pkgs.lib; mkForce "pg_isready -d template1";

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
            ];
            settings = {
              # "wal_level" = "logical";
              # "app.tenant" = "tenant#1";
              shared_preload_libraries = "auto_explain";
              "auto_explain.log_min_duration" = "0ms";
              "auto_explain.log_nested_statements" = true;
              "auto_explain.log_timing" = true;
              "auto_explain.log_analyze" = true;
              "auto_explain.log_buffers" = true;
              "auto_explain.log_settings" = true;
              "auto_explain.log_format" = "json";
              "auto_explain.log_triggers" = true;
              log_statement = "all";
              log_filename = "postgresql.log";
              log_destination = "stderr";
              logging_collector = true;
              # log_connections = true;
              # log_disconnections = true;
              lc_messages = "en_US.UTF-8";
            };
          };
        };
      };
    };
}

