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
    # pyproject-nix = {
    #   url = "github:nix-community/pyproject.nix";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, crane, extra-container, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      perSystem = { config, self', inputs', pkgs, lib, system, ... }: let
        n2c = inputs.nix2container.packages.${system};
        craneLib = crane.mkLib pkgs;
        crate = {
          src = craneLib.cleanCargoSource ./.;
          strictDeps = true;

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
          cargoArtifacts = craneLib.buildDepsOnly crate;
        };
      in {
        packages.httpg-dev = craneLib.buildPackage (crate // {
          CARGO_PROFILE = "dev";
          # inherit cargoArtifacts;
        });
        packages.httpg-release = craneLib.buildPackage (crate // {
          CARGO_PROFILE = "release";
          # inherit cargoArtifacts;
        });
        packages.httpg-test = craneLib.cargoTest (crate // {
          CARGO_PROFILE = "dev";
          # inherit cargoArtifacts;
          doCheck = true;
        });

        packages.pg_jitter = pkgs.stdenv.mkDerivation {
          pname = "pg_jitter";
          version = "0.2.0";

          srcs = [
            (pkgs.fetchFromGitHub {
              owner = "vladich";
              repo = "pg_jitter";
              rev = "v0.2.0";
              sha256 = "sha256-OYQQOU2/YujBSVUe6AXVbbY8+6ngw8xE5aNzZpZI+28=";
              name = "pg_jitter";
            })
            (pkgs.fetchFromGitHub {
              owner = "asmjit";
              repo = "asmjit";
              rev = "master";
              sha256 = "sha256-NC0V5KsYNyJ/hrgAkz6oTCwQmZ8eCWNSOUl+dyTKfJk=";
              name = "asmjit";
            })
            (pkgs.fetchFromGitHub {
              owner = "ashvardanian";
              repo = "StringZilla";
              rev = "v4.6.0";
              sha256 = "sha256-5WAD5ZpzhdIDv1kUVinc5z91N/tQVScO75kOPC1WWlY=";
              name = "stringzilla";
            })
            (pkgs.fetchFromGitHub {
              owner = "zherczeg";
              repo = "sljit";
              rev = "master";
              sha256 = "sha256-rpgcLzr+BYDhMguie7bvg6CppICkFpziXOq4hwTAvdw=";
              name = "sljit";
            })
          ];

          unpackCmd = ''
            cp -r $curSrc $(stripHash $curSrc)
          '';

          sourceRoot = "pg_jitter";

          nativeBuildInputs = with pkgs; [
            cmake
            postgresql_18.pg_config
          ];

          dontConfigure = true;

          buildPhase = ''
            ${pkgs.bash}/bin/bash build.sh \
              sljit \
              -DPG_CONFIG=${pkgs.postgresql_18.pg_config}/bin/pg_config

            # ${pkgs.bash}/bin/bash build.sh \
            #   asmjit \
            #   -DPG_CONFIG=${pkgs.postgresql_18.pg_config}/bin/pg_config
          '';

          installPhase = ''
            mkdir -p $out/lib
            cp -rv build/pg18/pg_jitter*.so $out/lib
          '';
        };

        # packages.pypsutil = pkgs.python3.pkgs.buildPythonPackage (pyproject-nix.lib.renderers.buildPythonPackage ({
        #   project = pyproject-nix.lib.project.loadPyproject {
        #     projectRoot = (pkgs.fetchFromGitHub {
        #         owner = "cptpcrd";
        #         repo = "pypsutil";
        #         rev = "master";
        #         sha256 = "sha256-8ZjNe7xfpcuKlADJyztkpODRpJkVcoHk18VuIhWwwMA=";
        #       });
        #   };
        #   python = pkgs.python3;
        #   pythonPackages = pkgs.python3Packages;
        # }) // {
        #   pname = "pypsutil";
        #   version = "master";
        # });

        # packages.pgtracer = pkgs.python3.pkgs.buildPythonApplication (pyproject-nix.lib.renderers.buildPythonPackage ({
        #   project = pyproject-nix.lib.project.loadPyproject {
        #     projectRoot = (pkgs.fetchFromGitHub {
        #         owner = "Aiven-Open";
        #         repo = "pgtracer";
        #         rev = "master";
        #         sha256 = "sha256-ftENAaretZZ9Ujjx2RW7GPMZwvZgzLa4tDDyGYyGUaU=";
        #       });
        #   };
        #   python = pkgs.python3;
        #   pythonPackages = pkgs.python3Packages // {
        #     pypsutil = self'.packages.pypsutil;
        #   };
        # }) // {
        #   pname = "pgtracer";
        #   version = "master";
        #   propagatedBuildInputs = [
        #     pkgs.bcc
        #     pkgs.libunwind
        #     pkgs.python3Packages.bcc
        #   ];
        #   patches = [
        #     ./unwind_version.patch
        #   ];
        #   postPatch = ''
        #     substituteInPlace src/pgtracer/ebpf/unwind.py --subst-var-by unwind_path "${lib.getLib pkgs.libunwind}/lib/libunwind-x86_64.so"
        #   '';
        # });

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
          PGHOST = "10.250.0.2";
          HTTPG_PRIVATE_KEY_FILE = "private-key-file";
          HTTPG_WEBPUSH_PRIVATE_KEY_FILE = "webpush.pem";
          # HTTPG_SMTP_PASSWORD_FILE = "${builtins.getEnv "PWD"}/smtp-password";
          HTTPG_ANON_ROLE = "person";
          HTTPG_INDEX_SQL = "table head union all table findings";
          HTTPG_LOGIN_QUERY = "select login()";
          HTTPG_SMTP_SENDER = "florian.klein@free.fr";
          HTTPG_SMTP_USER = "florian.klein@free.fr";
          HTTPG_SMTP_RELAY = "smtp://10.250.0.2:1025?tls=opportunistic";
          HTTPG_PUBLIC_DIR = "public";
          PG_USER = "httpg";
          PG_PASSWORD = "pg-password";
          PG_DBNAME = "httpg";
          PG_READ_HOST = "10.250.0.2";
          PG_WRITE_HOST = "10.250.0.2";
          PORT = "3000";
          RUST_LOG = "tokio_postgres=debug,httpg=debug,tower_http=debug";
          RUST_BACKTRACE = "1";
        };

        apps.up = {
          type = "app";
          program = pkgs.lib.getExe (pkgs.writeShellScriptBin "up"
            "nix run --impure .#container -- create --update-changed --restart-changed --start"
          );
        };

        packages.container = extra-container.lib.buildContainers {
          inherit system;
          nixpkgs = inputs.nixpkgs;

          config = {
            containers.httpg = {
              ephemeral = false;
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
                      "HTTPG_SMTP_SENDER=florian.klein@free.fr"
                      "HTTPG_SMTP_USER=florian.klein@free.fr"
                      "HTTPG_SMTP_RELAY=smtp://127.0.0.1:1025?tls=opportunistic"
                      "HTTPG_PUBLIC_DIR=${builtins.getEnv "PWD"}/public"
                      "PG_USER=httpg"
                      "PG_PASSWORD=${builtins.getEnv "PWD"}/pg-password"
                      "PG_DBNAME=httpg"
                      "PG_READ_HOST=10.250.0.2"
                      "PG_WRITE_HOST=10.250.0.2"
                      "PORT=3000"
                      "RUST_LOG=tokio_postgres=debug,httpg=debug,tower_http=debug"
                      "RUST_BACKTRACE=1"
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
                  # enableJIT = true;
                  package = pkgs.postgresql_18;
                  extensions = with pkgs.postgresql18Packages; [
                    wal2json
                    pg_ivm
                    pg_hint_plan
                    plv8
                    pgvector
                    pgsql-http
                    postgis
                    pgrouting
                    h3-pg
                    self'.packages.pg_jitter
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
                    log_statement = "all";
                    # log_min_messages = "DEBUG1";
                    # "auto_explain.log_nested_statements" = true;
                    # "auto_explain.log_min_duration" = 0;
                    "auto_explain.log_analyze" = true;
                    "auto_explain.log_buffers" = true;
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
                    client_connection_check_interval = "2s";
                    jit = "off";
                    jit_provider = "pg_jitter";
                    "pg_jitter.backend" = "sljit";
                  };
                };

                services.mailcatcher = {
                  enable = true;
                  http.ip = "0.0";
                  smtp.ip = "0.0";
                };
              });
            };
          };
        };
      };
    };
}

