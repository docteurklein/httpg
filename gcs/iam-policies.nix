[
  {
    ancestors = [ "projects/278563930937" ];
    assetType = "iam.googleapis.com/ServiceAccount";
    iamPolicy = {
      bindings = [
        {
          members = [
            "principalSet://iam.googleapis.com/projects/278563930937/locations/global/workloadIdentityPools/github/attribute.repository/docteurklein/httpg"
          ];
          role = "roles/iam.workloadIdentityUser";
        }
      ];
    };
    name = "//iam.googleapis.com/projects/gieze-421708/serviceAccounts/104798687631732191544";
    updateTime = "2025-12-13T13:52:06.150133Z";
  }
  {
    ancestors = [ "projects/278563930937" ];
    assetType = "run.googleapis.com/Service";
    iamPolicy = {
      bindings = [
        {
          members = [
            "principalSet://iam.googleapis.com/projects/278563930937/locations/global/workloadIdentityPools/github/attribute.repository/docteurklein/httpg"
          ];
          role = "roles/run.admin";
        }
      ];
    };
    name = "//run.googleapis.com/projects/gieze-421708/locations/europe-west1/services/httpg";
    updateTime = "2025-12-13T13:57:09.335521Z";
  }
  {
    ancestors = [ "projects/278563930937" ];
    assetType = "secretmanager.googleapis.com/Secret";
    iamPolicy = {
      bindings = [
        {
          members = [ "serviceAccount:278563930937-compute@developer.gserviceaccount.com" ];
          role = "roles/secretmanager.secretAccessor";
        }
      ];
    };
    name = "//secretmanager.googleapis.com/projects/278563930937/secrets/pg_password";
    updateTime = "2026-01-13T09:29:54.009051Z";
  }
  {
    ancestors = [ "projects/278563930937" ];
    assetType = "secretmanager.googleapis.com/Secret";
    iamPolicy = {
      bindings = [
        {
          members = [ "serviceAccount:278563930937-compute@developer.gserviceaccount.com" ];
          role = "roles/secretmanager.secretAccessor";
        }
      ];
    };
    name = "//secretmanager.googleapis.com/projects/278563930937/secrets/secret-1";
    updateTime = "2025-05-27T04:00:00Z";
  }
  {
    ancestors = [ "projects/278563930937" ];
    assetType = "secretmanager.googleapis.com/Secret";
    iamPolicy = {
      bindings = [
        {
          members = [ "serviceAccount:278563930937-compute@developer.gserviceaccount.com" ];
          role = "roles/secretmanager.secretAccessor";
        }
      ];
    };
    name = "//secretmanager.googleapis.com/projects/278563930937/secrets/smtp_password";
    updateTime = "2026-01-13T09:31:24.294258Z";
  }
  {
    ancestors = [ "projects/278563930937" ];
    assetType = "secretmanager.googleapis.com/Secret";
    iamPolicy = {
      bindings = [
        {
          members = [ "serviceAccount:278563930937-compute@developer.gserviceaccount.com" ];
          role = "roles/secretmanager.secretAccessor";
        }
      ];
    };
    name = "//secretmanager.googleapis.com/projects/278563930937/secrets/webpush-pem";
    updateTime = "2025-12-19T09:49:28.993994Z";
  }
  {
    ancestors = [ "projects/278563930937" ];
    assetType = "storage.googleapis.com/Bucket";
    iamPolicy = {
      bindings = [
        {
          members = [
            "projectEditor:gieze-421708"
            "projectOwner:gieze-421708"
          ];
          role = "roles/storage.legacyBucketOwner";
        }
        {
          members = [ "projectViewer:gieze-421708" ];
          role = "roles/storage.legacyBucketReader";
        }
      ];
      version = 1;
    };
    name = "//storage.googleapis.com/httpg-nginx";
    updateTime = "2026-10-26T04:00:00Z";
  }
]
