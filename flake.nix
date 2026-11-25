{
  description = "httpg";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    multiverse.url = "github:fzakaria/nixpkgs-multiverse";
    crane.url = "github:ipetkov/crane";
    # cargo-dyndrv = {
    #   url = "github:obsidiansystems/cargo-dyndrv";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    extra-container = {
      url = "github:extra-container/extra-container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, crane, extra-container, multiverse, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } ({moduleWithSystem, ...}: {
      systems = ["x86_64-linux"];

      flake = {

        gcs = let
          group = {
            "secretmanager.googleapis.com/Secret" = "secrets";
            "iam.googleapis.com/ServiceAccount" = "service-accounts";
            "run.googleapis.com/Service" = "services";
            "storage.googleapis.com/Bucket" = "storage buckets";
          };
          res_prefix = {
            "storage.googleapis.com/Bucket" = "gs://";
          };
        in rec {
          service = (import ./gcs/service.nix (self.packages."x86_64-linux".httpg-oci.imageRefUnsafe));
          resources = (builtins.fromJSON (builtins.readFile ./gcs/resources.json));
          iam-bindings = with nixpkgs; lib.flatten (lib.map
            (x: let
              r = lib.findFirst (r: r.name == x.name) null resources;
            in lib.map
              (binding: lib.map
                (member: ''
                  gcloud ${group."${x.assetType}"} add-iam-policy-binding \
                    "${res_prefix."${x.assetType}" or ""}${r.resource.data.name or r.resource.data.metadata.name}" \
                    --member "${member}" \
                    --role "${binding.role}"
                '')
                binding.members
              )
              x.iamPolicy.bindings 
            )
            (builtins.fromJSON (builtins.readFile ./gcs/iam-policies.json))
          );
        };

        nixosModules.postgres = moduleWithSystem ({pkgs, system, ...}: {config, lib, ...}: {

          boot.isNspawnContainer = true;

          system.stateVersion = "25.11";

          networking.firewall.allowedTCPPorts = [ 5432 ];
          networking.useDHCP = false;
          networking.enableIPv6 = true;

          users.users.postgres = {
            name = "postgres";
            group = "postgres";
            isSystemUser = true;
          };

          users.groups.postgres = { };

          services.pgbouncer = {
            enable = true;
            openFirewall = true;
            settings = {
              databases = {
                httpg = "host=127.0.0.1 user=httpg";
              };
              pgbouncer = {
                auth_type = "any";
                listen_addr = "0.0.0.0";
                pool_mode = "transaction";
              };
            };
          };

          systemd.services.pg_upgrade = let
              cfg = config.services.postgresql;
              new = pkgs.postgresql_19;
              old = multiverse.multiverse.${system}.versions.postgresql_19."19rc2";
            in lib.mkIf (true || new.psqlSchema != old.psqlSchema) { # major version
            enable = false;
            requiredBy = [ "postgresql.target" ];
            before = [ "pg_basebackup.service" "postgresql.service" "postgresql-setup.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "postgres";
              Group = "postgres";
            };
            script = ''
              set -eux

              export NEWDATA="${cfg.dataDir}"
              export NEWBIN="${cfg.finalPackage}/bin"

              if test -e "$NEWDATA/PG_VERSION"; then
                echo 'exists'
              fi

              export OLDDATA="/var/lib/postgresql/19"
              export OLDBIN="${old}/bin"

              install -d -m 0700 -o postgres -g postgres "$NEWDATA"
              cd "$NEWDATA"
              "$NEWBIN/initdb" -D "$NEWDATA"

              "$NEWBIN/pg_upgrade" \
                --old-datadir "$OLDDATA" --new-datadir "$NEWDATA" \
                --old-bindir "$OLDBIN" --new-bindir "$NEWBIN" \
                --jobs 4
            '';
          };

          services.postgresql = {
            enable = true;
            # enableJIT = true;
            package = pkgs.postgresql_19;
            extensions = with pkgs.postgresql19Packages; [
              (wal2json.overrideAttrs (prev: {
                # version = "git";
                src = pkgs.fetchFromGitHub {
                  owner = "eulerto";
                  repo = "wal2json";
                  rev = "master";
                  sha256 = "sha256-zRvMZbLOx6YAvNdAnKKRAcWamnCXsdGKrJtuwrkhq4M=";
                };
              }))
              pg_ivm
              pgvector
              pgsql-http
              postgis
              pgrouting
              h3-pg
              (plpython3.withPackages (p: []))
              pkgs.pg_jitter
              # self'.packages.pg-trickle
            ];

            enableTCPIP = true;
            ensureDatabases = [ "postgres" "httpg" ];
            ensureUsers = [
              {
                name = "postgres";
                ensureDBOwnership = true;
                ensureClauses = {
                  superuser = true;
                  createdb = true;
                };
              }
              {
                name = "httpg";
                ensureDBOwnership = true;
              }
            ];

            authentication = pkgs.lib.mkForce ''
              local all         all               trust
              host  all         all   0.0.0.0/0   trust
              host  replication all   0.0.0.0/0   trust
            '';

            settings = {
              allow_alter_system = false;
              wal_level = "logical";
              log_connections = true;
              log_lock_waits = true;
              log_disconnections = true;
              log_temp_files = 0;
              log_line_prefix = "%m [%p] %q%u@%d (%a) %e: ";
              # logging_collector = true;
              log_destination = nixpkgs.lib.mkForce "stderr";
              track_functions = "all";
              # log_min_messages = "DEBUG1";
              client_min_messages = "NOTICE";
              log_statement = "all";
              "auto_explain.log_min_duration" = -1;
              "auto_explain.log_nested_statements" = true;
              "auto_explain.log_format" = "json";
              "auto_explain.log_analyze" = true;
              "auto_explain.log_timing" = true; # perf hit
              "auto_explain.log_buffers" = true;
              "auto_explain.log_verbose" = true;
              "auto_explain.log_triggers" = true;
              # "auto_explain.log_parameter_max_length" = -1;
              shared_preload_libraries = "auto_explain,pg_stat_statements,pg_plan_advice,pg_stash_advice";
              output_plugin_libraries = "wal2json";
              "pg_plan_advice.feedback_warnings" = true;
              max_connections = 100;
              # shared_buffers = "${toString (builtins.ceil (ram / 4) / 1000 / 1000)} GB"; # 1/4th of RAM
              # work_mem =  builtins.ceil ((ram / max_connections) / 4); # 1/4th of RAM / max_connections
              # effective_cache_size = builtins.ceil(ram * 0.75); # 75% of total RAM
              # effective_cache_size = "${toString (builtins.ceil (ram * 0.75) / 1000 / 1000)} GB"; # 1/4th of RAM
              work_mem = "20MB";
              maintenance_work_mem = "1GB";
              checkpoint_completion_target = 0.9;
              wal_buffers = "16MB";
              default_statistics_target = 100;
              random_page_cost = 1.1;
              effective_io_concurrency = 200;
              min_wal_size = "1GB";
              max_wal_size = "4GB";
              max_wal_senders = 6;
              max_worker_processes = 6;
              max_parallel_workers_per_gather = 3;
              max_parallel_workers = 6;
              max_parallel_maintenance_workers = 3;
              client_connection_check_interval = "2s";
              jit = "on";
              jit_above_cost = 200;
              jit_inline_above_cost = 2000;
              jit_provider = "pg_jitter";
              "pg_jitter.backend" = "sljit";
              io_method = "io_uring";

              # "pg_trickle.cdc_mode" = "auto";
            };
          };
        });
      };

      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      perSystem = { config, self', inputs', pkgs, lib, system, ... }: let
        n2c = inputs.nix2container.packages.${system};
        craneLib = crane.mkLib pkgs;
        crate = {
          src = craneLib.cleanCargoSource ./.;
          strictDeps = true;

          doCheck = false;

          nativeBuildInputs = with pkgs; [
            mold clang pkg-config openssl.dev
          ];
          buildInputs = with pkgs; [
            openssl
          ];
          env = {
            RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
          };
          cargoArtifacts = craneLib.buildDepsOnly crate;
        };
      in {
        overlayAttrs = {
          inherit (config.packages) httpg-release gcloud pg_jitter;
        };
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            # inputs.cargo-dyndrv.overlays.default
            self.overlays.default
          ];
        };
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
  
        # packages.pg-trickle = pkgs.buildPgrxExtension (finalAttrs: {
        #   postgresql = pkgs.postgresql_18;
        #   cargo-pgrx = pkgs.cargo-pgrx_0_18_0;
        #   pname = "pg-trickle";
        #   version = "main";
        #   src = builtins.fetchGit {
        #     # url = "git@github.com:trickle-labs/pg-trickle.git";
        #     url = "/home/florian/work/docteurklein/pg-trickle";
        #     # rev = "9e16cd814f9855690aa12c3553a354bcf44e73ec";
        #     exportIgnore = false;
        #   };
        #   doCheck = false;

        #   cargoHash = "sha256-wXyt6zhOGOhNunYag3kLt4nDIfT0m7Z+KDTrNIZvizA=";
        # });

        packages.pg_jitter = pkgs.stdenv.mkDerivation {
          pname = "pg_jitter";
          version = "0.3.1";

          srcs = [
            (pkgs.fetchFromGitHub {
              owner = "vladich";
              repo = "pg_jitter";
              rev = "28f05edfda2c7a91935c185f2ca28aa96bfac3de";
              sha256 = "sha256-WU3JjWO19LZd0CJ+z0JZIMnwq2FHsiP7/zjWhiJmgwI=";
              name = "pg_jitter";
            })
            (pkgs.fetchFromGitHub {
              owner = "asmjit";
              repo = "asmjit";
              rev = "master";
              sha256 = "sha256-94vk+bFe+Fh0soyB5XNwxUtUkufh4G16cbIEQwRCWak=";
              name = "asmjit";
            })
            (pkgs.fetchFromGitHub {
              owner = "vladich";
              repo = "sljit";
              rev = "master";
              sha256 = "sha256-SBD81k+QNnpry7UoYhjFn64tuizhS2m9vZt5ZBibjwI=";
              name = "sljit";
            })
            (pkgs.fetchFromGitHub {
              owner = "vladich";
              repo = "mir-patched";
              rev = "master";
              sha256 = "sha256-k33ZtKj+1+eKE4hjGmrv+RS1DoJMFG7RliV4JD+S5eI=";
              name = "mir";
            })
            (pkgs.fetchFromGitHub {
              owner = "ashvardanian";
              repo = "StringZilla";
              rev = "v4.6.0";
              sha256 = "sha256-5WAD5ZpzhdIDv1kUVinc5z91N/tQVScO75kOPC1WWlY=";
              name = "stringzilla";
            })
          ];

          unpackCmd = ''
            cp -r $curSrc $(stripHash $curSrc)
          '';

          sourceRoot = "pg_jitter";

          nativeBuildInputs = with pkgs; [
            cmake
            python3
            postgresql_19.pg_config
            pcre2.dev
          ];

          dontConfigure = true;

          buildPhase = ''
            ${pkgs.bash}/bin/bash build.sh \
              sljit \
              -DPG_CONFIG=${pkgs.postgresql_19.pg_config}/bin/pg_config

            ${pkgs.bash}/bin/bash build.sh \
              asmjit \
              -DPG_CONFIG=${pkgs.postgresql_19.pg_config}/bin/pg_config

            ${pkgs.bash}/bin/bash build.sh \
              mir \
              -DPG_CONFIG=${pkgs.postgresql_19.pg_config}/bin/pg_config
          '';

          installPhase = ''
            mkdir -p $out/lib
            cp -rv build/pg19/pg_jitter*.so $out/lib
          '';
        };

        packages.pgmt = pkgs.rustPlatform.buildRustPackage {
          pname = "pgmt";
          version = "main";

          # src = (builtins.fetchGit {
          #   url = /home/florian/work/docteurklein/pgmt;
          #   # rev = "master";
          # });
          src = pkgs.fetchFromGitHub {
            owner = "gdpotter";
            repo = "pgmt";
            rev = "main";
            hash = "sha256-3rGfRLQuB3oRThp8ztlA4kjcVs+HTlnKo2yCuMt/GFs=";
          };
          cargoHash = "sha256-sEMuUdfmkMOs/uyFEyJHR+KhhYGDBNAptGtdGPToL8k=";

          doCheck = false;

          outputs = ["pgmt"];
        };

        packages.pgrust = pkgs.rustPlatform.buildRustPackage {
          pname = "pgrust";
          version = "main";

          src = pkgs.fetchFromGitHub {
            owner = "malisper";
            repo = "pgrust";
            rev = "main";
            hash = "sha256-winI+md0PXgJ84M6o9Y2CxZF8g8P7ss8udsa0FGsoNI=";
          };
          cargoHash = "sha256-rWDd0bwIso3llw3zittFhnXo9gSVgKtDvh58548ItJE=";

          cargoPatches = [
            ./pgrust.patch
          ];

          nativeBuildInputs = with pkgs; [
            perl
            pkg-config
          ];
          buildInputs = with pkgs; [
            openssl.dev
            re2.dev
            zstd
          ];

          doCheck = false;
        };

        packages.default = pkgs.httpg-release;

        packages.httpg-oci = n2c.nix2container.buildImage {
          name = "docteurklein/httpg";
          config = {
            entrypoint = ["${pkgs.httpg-release}/bin/httpg"];
            user = "1000";
          };
          copyToRoot = pkgs.buildEnv {
            name = "assets";
            paths = with pkgs.dockerTools; [
              (pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = ./public;
              })
              binSh
              pkgs.coreutils
              caCertificates
            ];
            pathsToLink = ["/public" "/" "/" "/etc"];
          };
        };

        packages.gcloud = (pkgs.google-cloud-sdk.withExtraComponents (with pkgs.google-cloud-sdk.components; [
          alpha
          config-connector
          gke-gcloud-auth-plugin
        ]));

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            comrak
            multimarkdown
            postgresql_19
            postgresql_19.debug
            postgresql_19.pg_config
            postgresql19Packages.postgis
            openssl.dev pkg-config
            cargo cargo-watch cargo-shear clippy rustc rust-analyzer
            cargo-flamegraph
            lldb
            mold clang
            biscuit-cli
            pkgs.extra-container
            pkgs.gcloud
            osmium-tool
            perf
          ];
          PSQLRC = "./.psqlrc";
          PGHOST = "10.250.1.2";
          PGUSER = "postgres";
          PGDATABASE = "httpg";
          HTTPG_PRIVATE_KEY_FILE = "private-key-file";
          HTTPG_WEBPUSH_PRIVATE_KEY_FILE = "webpush.pem";
          # HTTPG_SMTP_PASSWORD_FILE = "${builtins.getEnv "PWD"}/smtp-password";
          HTTPG_ANON_ROLE = "anon";
          HTTPG_INDEX_SQL = "select * from public.index()";
          HTTPG_LOGIN_QUERY = "select public.login($1)";
          HTTPG_SMTP_SENDER = "florian.klein@free.fr";
          HTTPG_SMTP_USER = "florian.klein@free.fr";
          HTTPG_SMTP_RELAY = "smtp://10.250.0.2:1025?tls=opportunistic";
          HTTPG_PUBLIC_DIR = "public";
          HTTPG_PG_WRITE_URL = "postgresql://httpg@10.250.1.2:6432/httpg?application_name=httpg";
          HTTPG_PG_READ_URL  = "postgresql://httpg@10.250.2.2:6432/httpg?application_name=httpg";
          PORT = "3000";
          # RUST_LOG = "httpg=debug,hyper_http=debug";
          RUST_LOG = "httpg=debug";
          RUST_BACKTRACE = "0";
        };

        apps.up = {
          type = "app";
          program = pkgs.lib.getExe (pkgs.writeShellScriptBin "up"
            "nix run --impure .#container -- create --update-changed --restart-changed --start"
          );
        };
        apps.deploy = {
          type = "app";
          program = pkgs.lib.getExe (pkgs.writeShellScriptBin "httpg" ''
            nix run .#httpg-oci.copyToRegistry
            nix eval .#gcs.service --json \
              | nix run .#gcloud -- run --project gieze-421708 \
                 services --region europe-west1 \
              replace -

          '');
            # ${self.gcs.iam-bindings}
        };

        packages.container = extra-container.lib.buildContainers {
          inherit system;
          nixpkgs = inputs.nixpkgs;

          config = {
            containers.httpg = lib.mkIf false {
              ephemeral = true;
              autoStart = true;

              extraFlags = [
                "--drop-capability=CAP_SYS_CHROOT"
                "-U"
                "--private-users=pick"
                "--private-users-ownership=chown"
              ];

              privateNetwork = true;
              hostBridge = "br0";
              localAddress = "10.250.0.2/16";

              bindMounts = {
                "${builtins.getEnv "PWD"}/private-key-file".isReadOnly = true;
                # "${builtins.getEnv "PWD"}/smtp-password".isReadOnly = true;
                # "${builtins.getEnv "PWD"}/webpush.pem".isReadOnly = true;
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

                networking.firewall.allowedTCPPorts = [ 1025 1080 3000 ];
                networking.useDHCP = false;
                networking.enableIPv6 = true;

                services.mailcatcher = {
                  enable = true;
                  http.ip = "0.0";
                  smtp.ip = "0.0";
                };

                systemd.services.httpg = {
                  enable = false;
                  wantedBy = [ "default.target" ];
                  serviceConfig = {
                    Type = "simple";
                    ExecStart = "${self'.packages.httpg-dev}/bin/httpg"; 
                    Environment = [
                      "HTTPG_PRIVATE_KEY_FILE=${builtins.getEnv "PWD"}/private-key-file"
                      "HTTPG_WEBPUSH_PRIVATE_KEY_FILE=${builtins.getEnv "PWD"}/webpush.pem"
                      # "HTTPG_SMTP_PASSWORD_FILE='${builtins.getEnv "PWD"}/smtp-password'"
                      "HTTPG_ANON_ROLE=anon"
                      "HTTPG_CACHE_DIR=.cache"
                      "HTTPG_INDEX_SQL='select * from public.index()"
                      "HTTPG_LOGIN_QUERY='select login($1)'"
                      "HTTPG_SMTP_SENDER=florian.klein@free.fr"
                      "HTTPG_SMTP_USER=florian.klein@free.fr"
                      "HTTPG_SMTP_RELAY=smtp://127.0.0.1:1025?tls=opportunistic"
                      "HTTPG_PUBLIC_DIR=${builtins.getEnv "PWD"}/public"
                      "HTTPG_PG_READ_URL=${builtins.getEnv "PWD"}/pg_write_url"
                      "HTTPG_PG_WRITE_URL=${builtins.getEnv "PWD"}/pg_read_url"
                      "PORT=3000"
                      "RUST_LOG=httpg=debug"
                      "RUST_BACKTRACE=0"
                    ];
                  };
                };
              });
            };

            containers.pgprimary = {
              ephemeral = false;
              autoStart = true;

              extraFlags = [
                "--drop-capability=CAP_SYS_CHROOT"
                "-U"
                "--private-users=pick"
                "--private-users-ownership=chown"
              ];

              privateNetwork = true;
              hostBridge = "br0";
              localAddress = "10.250.1.2/16";

              config = {
                imports = [
                  self.nixosModules.postgres
                ];
                boot.isNspawnContainer = true;

                services.pgbouncer.settings.pgbouncer.pool_mode = lib.mkForce "session";

                services.postgresql = {
                  initialScript = pkgs.writeText "backend-init-script" ''
                    SELECT * FROM pg_create_physical_replication_slot('replica1');
                  '';
                };
              };
            };

            containers.pgreplica = {
              ephemeral = true;
              autoStart = true;

              extraFlags = [
                "--drop-capability=CAP_SYS_CHROOT"
                "-U"
                "--private-users=pick"
                "--private-users-ownership=chown"
              ];

              privateNetwork = true;
              hostBridge = "br0";
              localAddress = "10.250.2.2/16";
              localAddress6 = "fdfd:b3f0:482::1";

              config = ({ pkgs, ... }: {
                imports = [
                  self.nixosModules.postgres
                ];
                boot.isNspawnContainer = true;
        
                networking.firewall.allowedTCPPorts = [ 5432 6432 ];

                services.postgresql = {
                  initialScript = null;
                  settings = {
                    listen_addresses = "*";
                    primary_conninfo = "host=10.250.1.2 port=5432 user=postgres dbname=postgres";
                    # recovery_min_apply_delay = "10s";
                    primary_slot_name = "replica1";
                  };
                };

                systemd.services.pg_basebackup = {
                  enable = true;
                  requiredBy = [ "postgresql.target" ];
                  before = [ "postgresql.service" "postgresql-setup.service" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                  };
                  script = ''
                    set -exu
                    if test -e /var/lib/postgresql/19/PG_VERSION; then
                      exit
                    fi
                    until ${pkgs.postgresql_19}/bin/pg_isready -h 10.250.1.2 -U postgres --timeout=5; do
                      sleep 2
                    done
                    ${pkgs.postgresql_19}/bin/pg_basebackup -h 10.250.1.2 -U postgres -D /var/lib/postgresql/19
                    touch /var/lib/postgresql/19/standby.signal
                    chown -R postgres: /var/lib/postgresql/19
                  '';
                };
              });
            };
          };
        };
      };
    });
}

