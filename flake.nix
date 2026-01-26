{
  description = "httpg";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs";
    crane.url = "github:ipetkov/crane";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    extra-container = {
      url = "github:erikarvstedt/extra-container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, crane, extra-container, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      perSystem = { config, self', inputs', pkgs, lib, system, ... }: let
        n2c = inputs.nix2container.packages.${system};
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
        packages.httpg-release = craneLib.buildPackage (crate // { CARGO_PROFILE = "release"; });

        packages.default = self'.packages.httpg-release;

        packages.oci = n2c.nix2container.buildImage {
          name = "docteurklein/httpg";
          config = {
            entrypoint = ["${self'.packages.httpg-release}/bin/httpg"];
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
        
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            postgresql_18
            cargo cargo-watch cargo-shear clippy rustc rust-analyzer openssl.dev pkg-config
            mold-wrapped clang
            biscuit-cli
            pkgs.extra-container
            (pkgs.google-cloud-sdk.withExtraComponents (with pkgs.google-cloud-sdk.components; [
              alpha
              config-connector
              gke-gcloud-auth-plugin
            ]))
          ];
        };

        packages.container = extra-container.lib.buildContainers {
          inherit system;
          nixpkgs = inputs.nixpkgs;

          config = {
            containers.httpg = {
              ephemeral = true;
              autoStart = true;

              extraFlags = [
                "--drop-capability=CAP_SYS_CHROOT"
                "-U"
                "--private-users=pick"
                "--private-users-ownership=chown"
              ];

              extra.addressPrefix = "10.250.0";

              bindMounts = {
                "${builtins.getEnv "PWD"}/private-key-file".isReadOnly = true;
                # "${builtins.getEnv "PWD"}/smtp-password".isReadOnly = true;
                "${builtins.getEnv "PWD"}/webpush.pem".isReadOnly = true;
                "${builtins.getEnv "PWD"}/pg-password".isReadOnly = true;
                "${builtins.getEnv "PWD"}/public".isReadOnly = true;
              };

              config = ({ pkgs, ... }: {
                assertions = [
                  {
                    assertion = builtins.getEnv "PWD" != "";
                    message = "run with --impure to access $PWD";
                  }
                ];
                boot.isNspawnContainer = true;
        
                system.stateVersion = "25.11";

                networking.firewall.allowedTCPPorts = [ 1025 1080 3000 5432 ];
                networking.useDHCP = false;

                systemd.services.httpg = {
                  enable = true;
                  wantedBy = [ "default.target" ];
                  serviceConfig = {
                    Type = "simple";
                    ExecStart = "${self'.packages.httpg-dev}/bin/httpg"; 
                    Environment = [
                      "HTTPG_PRIVATE_KEY_FILE=${builtins.getEnv "PWD"}/private-key-file"
                      "HTTPG_WEBPUSH_PRIVATE_KEY_FILE=${builtins.getEnv "PWD"}/webpush.pem"
                      # "HTTPG_SMTP_PASSWORD_FILE='${builtins.getEnv "PWD"}/smtp-password'"
                      "HTTPG_ANON_ROLE=person"
                      "HTTPG_INDEX_SQL='table head union all table findings'"
                      "HTTPG_LOGIN_QUERY='select login()'"
                      "HTTPG_SMTP_SENDER=sideral.underground@gmail.com"
                      "HTTPG_SMTP_USER=sideral.underground@gmail.com"
                      "HTTPG_SMTP_RELAY=smtp://127.0.0.1:1025"
                      "HTTPG_PUBLIC_DIR=${builtins.getEnv "PWD"}/public"
                      "PG_USER=httpg"
                      "PG_PASSWORD=${builtins.getEnv "PWD"}/pg-password"
                      "PG_DBNAME=httpg"
                      "PG_HOST=10.250.0.2"
                      "PG_READ_PG_HOST=10.250.0.2"
                      "PG_WRITE_PG_HOST=10.250.0.2"
                      "PORT=3000"
                      "RUST_LOG=tokio_postgres=debug,httpg=debug,tower_http=debug"
                    ];
                  };
                };

                users.users.postgres = {
                  name = "postgres";
                  group = "postgres";
                  isSystemUser = true;
                };

                users.groups.postgres = { };

                services.postgresql = {
                  enable = true;
                  package = pkgs.postgresql_18;
                  extensions = with pkgs.postgresql18Packages; [
                    wal2json
                    pg_ivm
                    pg_hint_plan
                    plv8
                    pgvector
                    pgsql-http
                  ];
                  enableTCPIP = true;

                  ensureDatabases = [ "postgres" "httpg" ];

                  ensureUsers = [
                    {
                      name = "postgres";
                      ensureDBOwnership = true;
                    }
                    {
                      name = "httpg";
                      ensureDBOwnership = true;
                    }
                  ];
                  initialScript = pkgs.writeText "backend-init-script" ''
                    CREATE ROLE postgres WITH SUPERUSER LOGIN CREATEDB;
                    CREATE USER httpg;
                  '';

                  authentication = pkgs.lib.mkForce ''
                    local all      all               trust
                    host  all      all   0.0.0.0/0   trust
                  '';

                  settings = {
                    wal_level = "logical";
                    log_connections = true;
                    log_disconnections = true;
                    log_temp_files = 0;
                    # logging_collector = true;
                    # log_destination = nixpkgs.lib.mkForce "syslog";
                    # log_statement = "all";
                    # "auto_explain.log_nested_statements" = true;
                    # "auto_explain.log_min_duration" = 0;
                    shared_preload_libraries = "auto_explain,pg_hint_plan,pg_stat_statements";
                    max_connections = 100;
                    # shared_buffers = "${toString (builtins.ceil (ram / 4) / 1000 / 1000)} GB"; # 1/4th of RAM
                    # work_mem =  builtins.ceil ((ram / max_connections) / 4); # 1/4th of RAM / max_connections
                    # effective_cache_size = builtins.ceil(ram * 0.75); # 75% of total RAM
                    # effective_cache_size = "${toString (builtins.ceil (ram * 0.75) / 1000 / 1000)} GB"; # 1/4th of RAM
                    maintenance_work_mem = "1GB";
                    checkpoint_completion_target = 0.9;
                    wal_buffers = "16MB";
                    default_statistics_target = 100;
                    random_page_cost = 1.1;
                    effective_io_concurrency = 200;
                    min_wal_size = "1GB";
                    max_wal_size = "4GB";
                    max_worker_processes = 6;
                    max_parallel_workers_per_gather = 3;
                    max_parallel_workers = 6;
                    max_parallel_maintenance_workers = 3;
                  };
                };

                services.mailcatcher = {
                  enable = true;
                  http.ip = "0.0";
                  # smtp.ip = "0.0";
                };
              });
            };
          };
        };
      };
    };
}

