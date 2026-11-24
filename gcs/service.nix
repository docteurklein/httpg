(image: {
  apiVersion = "serving.knative.dev/v1";
  kind = "Service";
  metadata = {
    name = "httpg";
    labels = {
      "cloud.googleapis.com/location" = "europe-west1";
    };
    annotations = {
      "run.googleapis.com/ingress" = "all";
      "run.googleapis.com/invoker-iam-disabled" = "true";
    };
  };
  spec = {
    template = {
      spec = {
        containers = [
          {
            image = "europe-docker.pkg.dev/artifact-registry-docker-cache/virtual-docker/${image}";
            name = "httpg";
            ports = [
              {name = "h2c"; containerPort = "3000";}
            ];
            env = [
              {name = "HTTPG_CACHE_DIR"; value = "/httpg-cache";}
              {name = "HTTPG_ANON_ROLE"; value = "anon";}
              {name = "HTTPG_INDEX_SQL"; value = "select * from public.index()";}
              {name = "HTTPG_LOGIN_QUERY"; value = "select public.login($1)";}
              {name = "HTTPG_SMTP_USER"; value = "sideral.underground@gmail.com";}
              {name = "HTTPG_PG_WRITE_URL"; value = "/secrets/pg_write_url/pg_write_url";}
              {name = "HTTPG_PG_READ_URL"; value = "/secrets/pg_read_url/pg_read_url";}
              {name = "HTTPG_PRIVATE_KEY_FILE"; value = "/secrets/private-key-file";}
              {name = "HTTPG_SMTP_PASSWORD_FILE"; value = "/secrets/smtp_password/smtp_password";}
              {name = "HTTPG_SMTP_RELAY"; value = "smtp://smtp.gmail.com?tls=required";}
              {name = "HTTPG_SMTP_SENDER"; value = "sideral.underground@gmail.com";}
              {name = "HTTPG_WEBPUSH_PRIVATE_KEY_FILE"; value = "/secrets/webpush.pem/webpush-pem";}
              # {name = "RUST_LOG"; value = "tokio_postgres=debug,httpg=debug";}
            ];
            resources = {
               limits = {
                 cpu = "1000m";
                 memory = "512Mi";
              };
            };
            startupProbe = {
              failureThreshold = "1";
              periodSeconds = "240";
              tcpSocket = {
                port = "3000";
              };
              timeoutSeconds = "240";
            };
            volumeMounts = [
              {
                mountPath = "/secrets";
                name = "secret-volume";
              }
              {
                mountPath = "/secrets/webpush.pem";
                name = "secret-1";
              }
              {
                mountPath = "/secrets/pg_write_url";
                name = "pg_write_url";
              }
              {
                mountPath = "/secrets/pg_read_url";
                name = "pg_read_url";
              }
              {
                mountPath = "/secrets/smtp_password";
                name = "secret-3";
              }
              {
                mountPath = "/httpg-cache";
                name = "gcs";
              }
            ];
          }
        ];
        volumes = [
          {
            name = "gcs";
            csi = {
              driver = "gcsfuse.run.googleapis.com";
              readOnly = false;
              volumeAttributes = {
                bucketName = "httpg-nginx";
                mountOptions = "uid=1000,gid=1000";
              };
            };
          }
          {
            name = "secret-volume";
            secret = {
              items = [
                {
                  key = "1";
                  path = "private-key-file";
                }
              ];
              secretName = "secret-1";
            };
          }
          {
            name = "secret-1";
            secret = {
              items = [
                {
                  key = "latest";
                  path = "webpush-pem";
                }
              ];
              secretName = "webpush-pem";
            };
          }
          {
            name = "pg_write_url";
            secret = {
              items = [
                {
                  key = "latest";
                  path = "pg_write_url";
                }
              ];
              secretName = "pg_write_url";
            };
          }
          {
            name = "pg_read_url";
            secret = {
              items = [
                {
                  key = "latest";
                  path = "pg_read_url";
                }
              ];
              secretName = "pg_read_url";
            };
          }
          {
            name = "secret-3";
            secret = {
              items = [
                {
                  key = "latest";
                  path = "smtp_password";
                }
              ];
              secretName = "smtp_password";
            };
          }
        ];
      };
    };
  };
})
